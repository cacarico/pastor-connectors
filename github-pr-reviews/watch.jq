# Plans the lines of one watch run. The input is slurped `gh api graphql
# --paginate` output: an array of pages of open pull requests. $refs holds
# the repository's kanban/ branches. Each output line starts with a tag that
# watch.sh acts on:
#
#   LINE <text>            a line for the watcher, as it is
#   ASK <sha> <branch>     a branch with no open pull request; watch.sh asks
#                          whether its head is already in the default branch
#   WARN <text>            a note for stderr
#
# Branch names go into lines an orchestrator reads and may paste into a
# shell, so a pull request or branch whose name is not shell-safe gets no
# line, only a WARN.
#
# A head branch name is only unique within its own repository: a fork's
# kanban/foo is not this repository's kanban/foo. So only pull requests from
# this repository name the pull request of a kanban/ branch; a fork's still
# gets its PR line.
include "branch" {search: "./"};

[.[].data.repository.pullRequests.nodes[]] as $prs
| ([$prs[] | select(.isCrossRepository == false and (.headRefName | safe_branch)) | {key: .headRefName, value: "#\(.number)"}]
   | from_entries) as $open
| ($prs[]
    | if .headRefName | safe_branch then
        "LINE PR #\(.number) branch=\(.headRefName) head=\(.headRefOid[0:7])"
        + " copilot=\(if any(.reviews.nodes[]; (.author.login // "") | test("copilot"; "i")) then "reviewed" else "none" end)"
        + " threads_open=\([.reviewThreads.nodes[] | select(.isResolved | not)] | length)"
        + " ci=\(.commits.nodes[0].commit.statusCheckRollup.state // "none")"
        + " merge=\(.mergeStateStatus)"
      else
        "WARN pull request #\(.number) has head branch \(.headRefName | tojson), which is not shell-safe; it gets no line"
      end),
  ($refs[]
    | (.ref | ltrimstr("refs/heads/")) as $branch
    | if $branch | safe_branch then
        if $open[$branch] then "LINE PUSHED \($branch) sha=\(.object.sha[0:7]) pr=\($open[$branch])"
        else "ASK \(.object.sha) \($branch)"
        end
      else
        "WARN branch \($branch | tojson) is not shell-safe; it gets no line"
      end)
