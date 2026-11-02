#!/bin/sh
# Poll connector. Reads pastor's handshake on stdin, lists the top-level
# messages from the listed users in one Slack channel since the cursor, and
# prints one item per message plus a cursor as JSON lines on stdout. Slack is
# reached through `curl` on the Web API, with SLACK_BOT_TOKEN (from the
# connector's .env) as the only credential.
set -eu

# GET $1 with the bot token. The header goes to curl on stdin (`-H @-`), not in
# its arguments, which any user on the machine can read from the process list.
slack_get() {
  printf 'Authorization: Bearer %s\n' "$token" | curl -sS -H @- "$1"
}

log() {
  jq -cn --arg level "$1" --arg message "$2" '{type: "log", level: $level, message: $message}'
}

fail() {
  echo "$1" >&2
  log error "$1"
  exit 1
}

read -r handshake || handshake='{}'
field() {
  printf '%s\n' "$handshake" | jq -r "$1"
}
channel=$(field '.config.channel // "" | tostring')
users=$(field '.config.users // "" | tostring')
# The cursor is the newest message ts of the last run, or, after a run that
# hit the page cap, a window still to read (see below); before there is one,
# pastor's `since` (now minus the job's backfill) bounds the first run.
in_cursor=$(field '.cursor // "" | tostring')
since=$(field '.since // "" | tostring')

if [ -z "$channel" ] || ! printf '%s\n' "$channel" | grep -Eq '^[A-Z0-9]+$'; then
  log error "connector.channel must be a channel ID like C0123456789, not \"$channel\""
  exit 2
fi
if [ -z "$users" ] || ! printf '%s\n' "$users" | grep -Eq '^[A-Z0-9]+(,[A-Z0-9]+)*$'; then
  log error "connector.users must be comma-separated Slack user IDs, not \"$users\""
  exit 2
fi
token="${SLACK_BOT_TOKEN:-}"
if [ -z "$token" ]; then
  log error "SLACK_BOT_TOKEN is not set"
  exit 2
fi

# conversations.history answers newest first. A run that reads only the
# newest pages of a busy channel must not move the cursor to the newest
# message: the older ones between the cursor and the oldest page read would
# never be asked for. So such a run hands back a window, `from|to|newest`,
# and the next run reads from `from` up to `to` (exclusive), newest first
# again, and so on until a run reaches `from`. Only then does the cursor
# become `newest`, the newest message of the whole backlog. A plain ts is the
# cursor of a run that read everything it asked for.
oldest=""
latest=""
carried=""
case "$in_cursor" in
  *'|'*)
    oldest=${in_cursor%%|*}
    rest=${in_cursor#*|}
    latest=${rest%%|*}
    carried=${rest#*|}
    ;;
  '') ;;
  *) oldest="$in_cursor" ;;
esac
for ts in "$oldest" "$latest" "$carried"; do
  if [ -n "$ts" ] && ! printf '%s\n' "$ts" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
    log error "the saved cursor \"$in_cursor\" is not a Slack ts or a window of them"
    exit 2
  fi
done
# With no cursor, `since` turned into epoch seconds bounds the first run.
if [ -z "$in_cursor" ] && [ -n "$since" ]; then
  oldest=$(jq -rn --arg s "$since" '$s | fromdateiso8601 | tostring')
fi

# One auth.test call gives the team's url, used to build message permalinks;
# it does not change, so later runs read it back from the job's state dir
# instead of calling it again.
state_dir="${PASTOR_CONNECTOR_STATE_DIR:-}"
team_url_cache="$state_dir/team_url"
if [ -n "$state_dir" ] && [ -s "$team_url_cache" ]; then
  team_url=$(cat "$team_url_cache")
else
  if ! resp=$(slack_get "https://slack.com/api/auth.test"); then
    fail "curl failed calling slack auth.test"
  fi
  if [ "$(printf '%s' "$resp" | jq -r '.ok')" != "true" ]; then
    fail "slack auth.test failed: $(printf '%s' "$resp" | jq -r '.error // "unknown error"')"
  fi
  team_url=$(printf '%s' "$resp" | jq -r '.url')
  if [ -n "$state_dir" ]; then
    printf '%s' "$team_url" > "$team_url_cache"
  fi
fi

# At most 5 pages (1,000 messages) per run. If Slack has more, the run is
# capped and hands back a window instead of a cursor (see above).
all_pages=""
next_cursor=""
page=0
while [ "$page" -lt 5 ]; do
  url="https://slack.com/api/conversations.history?channel=$channel&limit=200"
  if [ -n "$oldest" ]; then
    url="$url&oldest=$oldest"
  fi
  if [ -n "$latest" ]; then
    url="$url&latest=$latest"
  fi
  if [ -n "$next_cursor" ]; then
    url="$url&cursor=$next_cursor"
  fi
  if ! resp=$(slack_get "$url"); then
    fail "curl failed calling slack conversations.history"
  fi
  if [ "$(printf '%s' "$resp" | jq -r '.ok')" != "true" ]; then
    fail "slack conversations.history failed: $(printf '%s' "$resp" | jq -r '.error // "unknown error"')"
  fi
  all_pages="$all_pages
$resp"
  next_cursor=$(printf '%s' "$resp" | jq -r '.response_metadata.next_cursor // ""')
  page=$((page + 1))
  if [ -z "$next_cursor" ]; then
    break
  fi
done
capped=false
if [ -n "$next_cursor" ]; then
  capped=true
fi

printf '%s\n' "$all_pages" | jq -c -s \
  --arg channel "$channel" --arg users "$users" --arg team_url "$team_url" \
  --arg from "${oldest:-0}" --arg carried "$carried" --argjson capped "$capped" \
  -f items.jq
