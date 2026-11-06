# Shapes Slack conversations.history pages into pastor lines. The input is
# slurped: an array of page responses, each with a `.messages` array.
# Thread replies and messages with a subtype (joins, edits, bot messages,
# ...) never become items but still move the cursor, so a run whose newest
# messages are all like that does not ask for the same page forever.
#
# The cursor is the newest ts seen (`$carried` is a newer one, kept from the
# capped runs before this). When the run was capped, the pages are only the
# newest part of what was asked for: the cursor is then the window left to
# read, `from|oldest ts seen|newest`, as poll.sh describes. ts values are
# fixed-width, so they compare as strings.
($users | split(",")) as $user_list
| [.[].messages[]] | sort_by(.ts) as $all
| ([$carried, ($all[-1].ts // "")] | max) as $newest
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
  # Where the next run starts.
  (if $capped and ($all | length) > 0 then {type: "cursor", value: "\($from)|\($all[0].ts)|\($newest)"}
   elif $newest != "" then {type: "cursor", value: $newest}
   else empty end)
