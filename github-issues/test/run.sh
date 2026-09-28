#!/bin/sh
# Runs poll.sh and finish.sh against the fake gh in test/bin, which answers
# from canned JSON, so item shaping and the comment are checked offline.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export PATH="$here/bin:$PATH"
export GH_ARGS="$tmp/gh-args"
export GH_FIXTURE="$here/issues.json"
export GH_LOG="$tmp/gh-log"
cd "$here/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

gh_got() {
  grep -qx -- "$1" "$GH_ARGS" || fail "gh was not called with $1"
}

echo "poll: items and cursor from a fixture, since taken from the cursor"
printf '%s\n' '{"config":{"repo":"acme/widgets"},"cursor":"2026-09-20T08:00:00Z","since":"2026-09-01T00:00:00Z"}' \
  | sh poll.sh > "$tmp/out"
jq -S -c . "$tmp/out" > "$tmp/got"
jq -S -c . test/expected.jsonl > "$tmp/want"
diff -u "$tmp/want" "$tmp/got" || fail "poll output differs from test/expected.jsonl"
gh_got api
gh_got --paginate
gh_got repos/acme/widgets/issues
gh_got labels=pastor
gh_got state=open
gh_got since=2026-09-20T08:00:00Z

echo "poll: label and state from the config, since from the handshake when there is no cursor"
printf '%s\n' '{"config":{"repo":"acme/widgets","label":"agent","state":"all"},"cursor":null,"since":"2026-09-01T00:00:00Z"}' \
  | sh poll.sh > "$tmp/out"
gh_got labels=agent
gh_got state=all
gh_got since=2026-09-01T00:00:00Z

echo "poll: nothing new means no items and no cursor"
printf '[]\n' > "$tmp/empty.json"
printf '%s\n' '{"config":{"repo":"acme/widgets"},"cursor":null,"since":"2026-09-01T00:00:00Z"}' \
  | GH_FIXTURE="$tmp/empty.json" sh poll.sh > "$tmp/out"
if jq -e 'select(.type != "log")' "$tmp/out" > /dev/null; then
  fail "an empty page produced items or a cursor"
fi

echo "poll: a config without repo is refused before gh runs"
rm -f "$GH_ARGS"
if printf '%s\n' '{"config":{},"cursor":null,"since":"2026-09-01T00:00:00Z"}' | sh poll.sh > "$tmp/out" 2> /dev/null; then
  fail "accepted a config without repo"
fi
[ ! -e "$GH_ARGS" ] || fail "gh ran without a repo"
jq -e 'select(.type == "log" and .level == "error")' "$tmp/out" > /dev/null || fail "no error log for the missing repo"

echo "poll: a repo that is not owner/name is refused"
if printf '%s\n' '{"config":{"repo":"acme/widgets/issues?x=1"},"cursor":null,"since":"2026-09-01T00:00:00Z"}' | sh poll.sh > /dev/null 2>&1; then
  fail "accepted a repo with a path in it"
fi

# Each finish test gets its own state dir, as pastor gives each job one.
finish() {
  PASTOR_CONNECTOR_STATE_DIR="$tmp/state" sh finish.sh "$@"
}
# The finish stdin with a different state, branch or item.
finish_input() {
  jq -c "$1" test/finish.json
}

echo "finish: a done task comments on its issue with its id, state and branch"
rm -rf "$tmp/state" "$GH_ARGS" "$tmp/gh-log"
mkdir "$tmp/state"
finish < test/finish.json
gh_got issue
gh_got comment
gh_got https://github.com/acme/widgets/issues/12
gh_got --body
grep -q 't-7' "$GH_ARGS" || fail "the comment does not name task t-7"
grep -q '`done`' "$GH_ARGS" || fail "the comment does not name the state"
grep -q 'pastor/issue-12' "$GH_ARGS" || fail "the comment does not name the branch"
grep -q 'pi-3' "$GH_ARGS" && fail "the comment names the machine on a public issue"
grep -qx 'pr list --repo acme/widgets --head pastor/issue-12 --state all --json url' "$tmp/gh-log" \
  || fail "the pull request was not looked up by the task's branch"

echo "finish: a second finish for the same task comments nothing"
rm -f "$GH_ARGS"
finish < test/finish.json
[ ! -e "$GH_ARGS" ] || fail "gh ran for a task already commented on"

echo "finish: a failed task comments with its state"
rm -rf "$tmp/state" "$GH_ARGS"
mkdir "$tmp/state"
finish_input '.state = "failed" | .task.state = "failed" | .task.error = "agent process exited"' | finish
grep -q '`failed`' "$GH_ARGS" || fail "the comment does not name the failed state"

echo "finish: an existing pull request adds its link"
rm -rf "$tmp/state" "$GH_ARGS"
mkdir "$tmp/state"
GH_PRS=test/prs.json finish < test/finish.json
grep -q 'https://github.com/acme/widgets/pull/31' "$GH_ARGS" || fail "the comment has no pull request link"

echo "finish: a task without a branch comments without looking for a pull request"
rm -rf "$tmp/state" "$GH_ARGS" "$tmp/gh-log"
mkdir "$tmp/state"
finish_input '.branch = null' | finish
gh_got comment
grep -q '^pr ' "$tmp/gh-log" && fail "looked for a pull request without a branch"

echo "finish: gh failing to comment is logged and exits non-zero"
rm -rf "$tmp/state"
mkdir "$tmp/state"
if GH_FAIL="issue comment" finish < test/finish.json 2> "$tmp/err"; then
  fail "a failed comment exited 0"
fi
grep -q 'issues/12' "$tmp/err" || fail "the failure does not name the issue"
grep -q '502' "$tmp/err" || fail "gh's own error is not in the log"
GH_FAIL= finish < test/finish.json
gh_got comment

echo "finish: gh failing to list pull requests still comments, without a link"
rm -rf "$tmp/state" "$GH_ARGS"
mkdir "$tmp/state"
GH_FAIL="pr list" finish < test/finish.json 2> "$tmp/err"
gh_got comment
grep -q 'pull request' "$tmp/err" || fail "the failed lookup is not logged"
grep -q 'No pull request' "$GH_ARGS" && fail "the comment says there is no pull request when it could not look"

echo "finish: --dry-run prints the comment and posts nothing"
rm -rf "$tmp/state" "$tmp/gh-log"
mkdir "$tmp/state"
GH_PRS=test/prs.json finish --dry-run < test/finish.json > "$tmp/out"
grep -q 't-7' "$tmp/out" || fail "the dry run did not print the comment"
grep -q 'pull/31' "$tmp/out" || fail "the dry run left out the pull request"
grep -q '^issue ' "$tmp/gh-log" && fail "the dry run commented"
finish < test/finish.json
gh_got comment

echo "finish: --dry-run needs no state dir"
sh finish.sh --dry-run < test/finish.json > "$tmp/out"
grep -q 't-7' "$tmp/out" || fail "the dry run without a state dir printed nothing"

echo "finish: a task whose item has no issue url comments nothing"
rm -rf "$tmp/state" "$GH_ARGS"
mkdir "$tmp/state"
finish_input '.task.item = null' | finish
[ ! -e "$GH_ARGS" ] || fail "gh ran for a task without an issue"

echo "ok"
