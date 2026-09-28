#!/bin/sh
# The [watch] command `pastor watch` runs each interval. Prints the state of
# one repository as it is now, one line per open pull request and one per
# kanban/ branch, in the shape the orchestrating-pastor-tiered skill matches:
#
#   PR #<n> branch=<b> head=<sha> copilot=<reviewed|none> threads_open=<n> ci=<state> merge=<state>
#   PUSHED kanban/<key> sha=<sha> pr=<#n|merged|none>
#
# pastor watch prints a line only the first time it sees it, so this prints
# everything every run. pastor passes no arguments, so the repository comes
# from WATCH_REPO in the connector's .env; --repo overrides it when run by
# hand. GitHub is reached through gh, so gh's own login is the credential.
set -eu

repo=${WATCH_REPO:-}
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      if [ $# -lt 2 ]; then
        echo "watch.sh: --repo needs owner/name" >&2
        exit 2
      fi
      repo=$2
      shift 2
      ;;
    *)
      echo "watch.sh: unknown argument \"$1\"; the only one is --repo owner/name" >&2
      exit 2
      ;;
  esac
done
if [ -z "$repo" ]; then
  echo "watch.sh: no repository; set WATCH_REPO=owner/name in the connector's .env" >&2
  exit 2
fi
# The repo goes into a query and a URL: keep it to exactly two plain segments.
if ! printf '%s\n' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  echo "watch.sh: the repository must be owner/name, not \"$repo\"" >&2
  exit 2
fi

query='
query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef { name }
    pullRequests(states: OPEN, first: 50, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number
        headRefName
        isCrossRepository
        headRefOid
        mergeStateStatus
        reviews(last: 100) { nodes { author { login } } }
        reviewThreads(first: 100) { nodes { isResolved } }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
}'
if ! pages=$(gh api graphql --paginate -f query="$query" -f owner="${repo%%/*}" -f name="${repo#*/}"); then
  echo "watch.sh: gh api graphql failed for $repo" >&2
  exit 1
fi
if ! refs=$(gh api --paginate "repos/$repo/git/matching-refs/heads/kanban/"); then
  echo "watch.sh: gh could not list the kanban/ branches of $repo" >&2
  exit 1
fi
base=$(printf '%s\n' "$pages" | jq -r -s '.[0].data.repository.defaultBranchRef.name // ""')
plan=$(printf '%s\n' "$pages" \
  | jq -r -s --argjson refs "$(printf '%s\n' "$refs" | jq -s 'add // []')" -f watch.jq)

# Kanban branches are not deleted after their pull request merges, so a
# branch with no open pull request whose head is in the default branch is
# merged, not waiting for one. A commit in the default branch stays there, so
# a yes is kept in the state dir and not asked again; a no may turn into a
# yes when the branch merges, so it is asked every run.
seen=
if [ -n "${PASTOR_CONNECTOR_STATE_DIR:-}" ]; then
  seen=$PASTOR_CONNECTOR_STATE_DIR/in-default-branch
fi
merged() {
  [ -n "$base" ] || return 1
  if [ -n "$seen" ] && [ -f "$seen" ] && grep -qx "$1" "$seen"; then
    return 0
  fi
  if ! got=$(gh api "repos/$repo/compare/$base...$1"); then
    echo "watch.sh: gh could not compare $1 with $base in $repo" >&2
    exit 1
  fi
  case $(printf '%s\n' "$got" | jq -r '.status') in
    identical | behind) ;;
    *) return 1 ;;
  esac
  if [ -n "$seen" ]; then
    echo "$1" >> "$seen"
  fi
}

# Lines are collected and printed at the end, so a run that fails halfway
# prints none: pastor watch drops the output of a failed run anyway, and a
# half-written pr=none would read as a branch waiting for a pull request.
nl='
'
lines=
while read -r tag rest; do
  case "$tag" in
    LINE) lines=$lines$rest$nl ;;
    WARN) echo "watch.sh: $rest" >&2 ;;
    ASK)
      sha=${rest%% *}
      branch=${rest#* }
      pr=none
      if merged "$sha"; then
        pr=merged
      fi
      lines="${lines}PUSHED $branch sha=$(printf '%.7s' "$sha") pr=$pr$nl"
      ;;
  esac
done << PLAN
$plan
PLAN
printf '%s' "$lines"
