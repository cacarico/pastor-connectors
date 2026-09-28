#!/bin/sh
# [finish] command. pastor runs it once when a task of one of this connector's
# jobs ends done or failed, with the task, its final state and its branch on
# stdin. It comments on the task's issue with the task id, the state, the
# branch and the branch's pull request, so the person who filed the issue
# learns where the work went without watching pastor. Closing the issue is
# left to GitHub: the job's prompt has the agent write "Fixes #N", so merging
# the branch closes it.
#
# --dry-run prints the comment instead of posting it and keeps no record.
set -eu

dry_run=false
case "${1:-}" in
  --dry-run) dry_run=true ;;
  "") ;;
  *)
    echo "usage: finish.sh [--dry-run] < task-end.json" >&2
    exit 2
    ;;
esac

input=$(cat)
field() {
  printf '%s\n' "$input" | jq -r "$1"
}
id=$(field '.task.id // "" | tostring')
url=$(field '.task.item.url // ""')
state=$(field '.state // .task.state // "" | tostring')
branch=$(field '.branch // ""')

if [ -z "$url" ]; then
  echo "task t-$id has no item url; no issue to comment on" >&2
  exit 0
fi
# The id names the record file and the url gives gh a repository: keep both
# to what pastor and GitHub hand out.
case "$id" in
  '' | *[!0-9]*)
    echo "task id \"$id\" is not a number" >&2
    exit 2
    ;;
esac
repo=$(printf '%s\n' "$url" | sed -n 's|^https://github\.com/\([A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*\)/issues/[0-9]*$|\1|p')
if [ -z "$repo" ]; then
  echo "\"$url\" is not a GitHub issue url" >&2
  exit 2
fi

# pastor runs this once per task but keeps that in memory, so a restarted
# head could run it again. A file per task in the job's state dir is what
# keeps the issue to one comment.
record=""
if [ "$dry_run" = false ]; then
  if [ -z "${PASTOR_CONNECTOR_STATE_DIR:-}" ]; then
    echo "PASTOR_CONNECTOR_STATE_DIR is not set; run it from pastor, or with --dry-run" >&2
    exit 2
  fi
  record="$PASTOR_CONNECTOR_STATE_DIR/finished-t-$id"
  if [ -e "$record" ]; then
    echo "task t-$id already commented on $url" >&2
    exit 0
  fi
fi

pr=""
looked=false
if [ -n "$branch" ]; then
  # A failed lookup costs the link, not the comment.
  if prs=$(gh pr list --repo "$repo" --head "$branch" --state all --json url); then
    pr=$(printf '%s\n' "$prs" | jq -r '.[0].url // ""')
    looked=true
  else
    echo "could not look up a pull request for $branch in $repo; commenting without one" >&2
  fi
fi

# The machine and the error stay out: the issue may be public, and both can
# name hosts or paths. They are in pastor's task describe.
body=$(jq -rn --arg id "$id" --arg state "$state" --arg branch "$branch" --arg pr "$pr" --arg looked "$looked" '
  "pastor task t-\($id) ended `\($state)`"
  + (if $branch != "" then " on branch `\($branch)`." else "." end)
  + (if $pr != "" then "\n\nPull request: \($pr)"
     elif $looked == "true" then "\n\nNo pull request for this branch yet."
     else "" end)
')

if [ "$dry_run" = true ]; then
  printf 'would comment on %s:\n\n%s\n' "$url" "$body"
  exit 0
fi
if ! gh issue comment "$url" --body "$body"; then
  echo "gh issue comment failed for $url (task t-$id)" >&2
  exit 1
fi
: > "$record"
