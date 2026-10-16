# Shapes Slack conversations.history pages into pastor lines. The input is
# slurped: an array of page responses, each with a `.messages` array.
# Thread replies and messages with a subtype (joins, edits, bot messages,
# ...) never become items but still move the cursor, so a run whose newest
# messages are all like that does not ask for the same page forever.
($users | split(",")) as $user_list
| [.[].messages[]] | sort_by(.ts | tonumber) as $all
| [
    $all[]
    | select(
        (.thread_ts == null or .thread_ts == .ts)
        and ((.subtype // null) == null)
        and (.user as $u | $user_list | index($u) != null)
      )
  ] as $items
| {
    type: "log",
    level: "info",
    message: "\($items | length) items from \($channel) for \($user_list | join(","))"
  },
  ($items[] | {
    type: "item",
    key: "\($channel):\(.ts)",
    title: ((.text // "") | split("\n")[0])[0:80],
    body: (.text // ""),
    url: "\($team_url)archives/\($channel)/p\(.ts | gsub("\\."; ""))",
    author: .user,
    channel: $channel,
    ts: .ts
  }),
  # The newest message seen, filtered or not; the next run asks from here on.
  (if ($all | length) > 0 then {type: "cursor", value: $all[-1].ts} else empty end)
