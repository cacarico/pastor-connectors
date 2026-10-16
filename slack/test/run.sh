#!/bin/sh
# Runs poll.sh against the fake curl in test/bin, which answers by Slack Web
# API method from fixtures and records its args, so item shaping, paging and
# config validation are checked offline.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export PATH="$here/bin:$PATH"
export SLACK_BOT_TOKEN="xoxb-test-token"
export CURL_LOG="$tmp/curl-log"
export CURL_AUTH_FIXTURE="$here/auth.json"
export CURL_HISTORY_FIXTURE="$here/history.json"
export CURL_HISTORY_PAGE2_FIXTURE="$here/history2.json"
cd "$here/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

curl_got() {
  grep -q -- "$1" "$CURL_LOG" || fail "curl was not called with $1"
}

# $1 = extra jq filter applied on top of a base handshake for C0TEST/U0ANA,U0BO
handshake() {
  jq -cn '{config: {channel: "C0TEST", users: "U0ANA,U0BO"}, cursor: null, since: null}' | jq -c "$1"
}

echo "poll: items and cursor from fixtures, oldest taken from the cursor"
: > "$CURL_LOG"
handshake '.cursor = "1700000000.000000" | .since = "2026-09-01T00:00:00Z"' \
  | sh poll.sh > "$tmp/out"
jq -S -c . "$tmp/out" > "$tmp/got"
jq -S -c . test/expected.jsonl > "$tmp/want"
diff -u "$tmp/want" "$tmp/got" || fail "poll output differs from test/expected.jsonl"
curl_got "https://slack.com/api/auth.test"
curl_got "channel=C0TEST"
curl_got "oldest=1700000000.000000"
curl_got "cursor=page2cursor"

echo "poll: paging follows next_cursor (both pages' messages are in the output)"
grep -q 'C0TEST:1700000100.000000' "$tmp/got" || fail "the oldest message, only on page 2, is missing"

echo "poll: top-level only, thread replies dropped"
grep -q 'C0TEST:1700000520.000000' "$tmp/got" && fail "a thread reply became an item"

echo "poll: subtypes skipped"
grep -q '1700000460.000000' "$tmp/got" && fail "a subtyped message became an item"

echo "poll: users filter drops messages from unlisted users"
grep -q 'U0CARL' "$tmp/got" && fail "a message from an unlisted user became an item"

echo "poll: cursor wins over since when both are given"
: > "$CURL_LOG"
handshake '.cursor = "1700000000.000000" | .since = "2026-01-01T00:00:00Z"' \
  | sh poll.sh > /dev/null
curl_got "oldest=1700000000.000000"
grep -q 'oldest=1767225600' "$CURL_LOG" && fail "since was used even though a cursor was given"

echo "poll: oldest from since when there is no cursor"
: > "$CURL_LOG"
handshake '.cursor = null | .since = "2026-09-01T00:00:00Z"' \
  | sh poll.sh > /dev/null
curl_got "oldest=1788220800"

echo "poll: no messages means no cursor"
: > "$CURL_LOG"
export CURL_HISTORY_FIXTURE="$here/empty.json"
export CURL_HISTORY_PAGE2_FIXTURE="$here/empty.json"
handshake '.cursor = null | .since = "2026-09-01T00:00:00Z"' | sh poll.sh > "$tmp/out"
if jq -e 'select(.type == "cursor" or .type == "item")' "$tmp/out" > /dev/null; then
  fail "an empty page produced items or a cursor"
fi

echo "poll: ok:false from Slack exits non-zero, with no items"
: > "$CURL_LOG"
export CURL_HISTORY_FIXTURE="$here/error.json"
export CURL_HISTORY_PAGE2_FIXTURE="$here/error.json"
if handshake '.config.users = "U0ANA"' | sh poll.sh > "$tmp/out" 2> "$tmp/err"; then
  fail "an ok:false response exited 0"
fi
jq -e 'select(.type == "item" or .type == "cursor")' "$tmp/out" > /dev/null && fail "an ok:false response produced an item or a cursor"
jq -e 'select(.type == "log" and .level == "error")' "$tmp/out" > /dev/null || fail "no error log for the ok:false response"
grep -q 'not_in_channel' "$tmp/err" || fail "the failure does not name Slack's error"
export CURL_HISTORY_FIXTURE="$here/history.json"
export CURL_HISTORY_PAGE2_FIXTURE="$here/history2.json"

echo "poll: a config without channel or users is refused before curl runs"
: > "$CURL_LOG"
if jq -cn '{config: {}, cursor: null, since: null}' | sh poll.sh > "$tmp/out" 2> "$tmp/err"; then
  fail "accepted a config without channel or users"
fi
[ ! -s "$CURL_LOG" ] || fail "curl ran without a channel or users"
jq -e 'select(.type == "log" and .level == "error")' "$tmp/out" > /dev/null || fail "no error log for the missing channel"

echo "poll: a malformed channel or users is refused before curl runs"
: > "$CURL_LOG"
if handshake '.config.channel = "not-a-channel"' | sh poll.sh > /dev/null 2> "$tmp/err"; then
  fail "accepted a malformed channel"
fi
[ ! -s "$CURL_LOG" ] || fail "curl ran with a malformed channel"
: > "$CURL_LOG"
if handshake '.config.users = "ana, bo"' | sh poll.sh > /dev/null 2> "$tmp/err"; then
  fail "accepted malformed users"
fi
[ ! -s "$CURL_LOG" ] || fail "curl ran with malformed users"

echo "poll: a missing token is refused before curl runs"
: > "$CURL_LOG"
if handshake '.' | SLACK_BOT_TOKEN= sh poll.sh > "$tmp/out" 2> "$tmp/err"; then
  fail "accepted a missing token"
fi
[ ! -s "$CURL_LOG" ] || fail "curl ran without a token"
jq -e 'select(.type == "log" and .level == "error" and (.message | contains("SLACK_BOT_TOKEN")))' "$tmp/out" > /dev/null \
  || fail "no error naming SLACK_BOT_TOKEN for the missing token"

echo "poll: the team url is cached in the state dir and not fetched again"
: > "$CURL_LOG"
mkdir "$tmp/state"
handshake '.' | PASTOR_CONNECTOR_STATE_DIR="$tmp/state" sh poll.sh > /dev/null
[ "$(grep -c 'auth.test' "$CURL_LOG")" -eq 1 ] || fail "auth.test was not called once on a cold cache"
[ -s "$tmp/state/team_url" ] || fail "the team url was not cached"
: > "$CURL_LOG"
handshake '.' | PASTOR_CONNECTOR_STATE_DIR="$tmp/state" sh poll.sh > /dev/null
grep -q 'auth.test' "$CURL_LOG" && fail "auth.test was called again with a warm cache"

echo "poll: pagination stops at 5 pages even when Slack keeps paging"
: > "$CURL_LOG"
export CURL_HISTORY_FIXTURE="$here/loop.json"
export CURL_HISTORY_PAGE2_FIXTURE="$here/loop.json"
handshake '.config.users = "U0ANA"' | sh poll.sh > /dev/null
[ "$(grep -c 'conversations.history' "$CURL_LOG")" -eq 5 ] || fail "conversations.history was not called exactly 5 times"

echo "ok"
