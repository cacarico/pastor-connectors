#!/bin/sh
# Runs watch.sh against the fake gh in test/bin, which answers from canned
# JSON, so the PR and PUSHED lines are checked offline.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export PATH="$here/bin:$PATH"
export GH_ARGS="$tmp/gh-args"
export GH_FIXTURE="$here/watch-pulls.json"
export GH_REFS="$here/watch-refs.json"
export GH_COMPARE="$here/watch-compare.txt"
export WATCH_REPO=acme/widgets
unset PASTOR_CONNECTOR_STATE_DIR GH_FAIL
cd "$here/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

gh_got() {
  grep -qx -- "$1" "$GH_ARGS" || fail "gh was not called with $1"
}

# How many times gh compared a commit whose sha starts with $1.
compared() {
  grep -c "^repos/acme/widgets/compare/trunk\.\.\.$1" "$GH_ARGS" || true
}

watch() {
  rm -f "$GH_ARGS"
  sh watch.sh "$@" > "$tmp/out" 2> "$tmp/err"
}

echo "watch: one PR line per open pull request, one PUSHED line per kanban branch"
watch
diff -u test/watch-expected.txt "$tmp/out" || fail "watch output differs from test/watch-expected.txt"
gh_got graphql
gh_got --paginate
gh_got owner=acme
gh_got name=widgets
gh_got repos/acme/widgets/git/matching-refs/heads/kanban/
# A branch with an open pull request needs no compare; the base is the
# repository's default branch.
[ "$(compared 3f2a9c1)" = 0 ] || fail "compared a branch that has a pull request"
[ "$(compared 1111111)" = 1 ] || fail "did not compare kanban/bbb with trunk"
[ "$(compared 2222222)" = 1 ] || fail "did not compare kanban/ccc with trunk"

echo "watch: --repo wins over WATCH_REPO"
watch --repo other/thing
gh_got owner=other
gh_got name=thing
gh_got repos/other/thing/git/matching-refs/heads/kanban/

echo "watch: a commit found in the default branch is not asked about again; one that is not, is"
export PASTOR_CONNECTOR_STATE_DIR="$tmp/state"
mkdir -p "$PASTOR_CONNECTOR_STATE_DIR"
watch
watch
diff -u test/watch-expected.txt "$tmp/out" || fail "a second run printed something else"
[ "$(compared 1111111)" = 0 ] || fail "compared kanban/bbb again, though it is in trunk"
[ "$(compared 2222222)" = 1 ] || fail "did not compare kanban/ccc again"
unset PASTOR_CONNECTOR_STATE_DIR

echo "watch: a repository with no pull requests and no kanban branches prints nothing"
printf '%s\n' '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' > "$tmp/empty.json"
echo '[]' > "$tmp/norefs.json"
GH_FIXTURE="$tmp/empty.json" GH_REFS="$tmp/norefs.json"
watch
[ ! -s "$tmp/out" ] || fail "printed $(cat "$tmp/out")"

echo "watch: a branch name that is not shell-safe gives no line"
for branch in 'x;touch pwned' '$(id)' '-f' 'a..b' 'has space' 'a`b`' "it's"; do
  b=$(jq -n --arg b "$branch" '$b')
  jq "(.data.repository.pullRequests.nodes[] | select(.number == 42)).headRefName = $b" test/watch-pulls.json > "$tmp/pulls.json"
  jq ".[2].ref = (\"refs/heads/kanban/\" + $b)" test/watch-refs.json > "$tmp/refs.json"
  GH_FIXTURE="$tmp/pulls.json" GH_REFS="$tmp/refs.json"
  watch
  if grep -q -e '#42' "$tmp/out"; then
    fail "pull request branch $branch gave a line"
  fi
  grep -q '#42' "$tmp/err" || fail "no warning for pull request #42 with branch $branch"
  # Under kanban/ a leading - is harmless; every other name here is not.
  if [ "$branch" != -f ]; then
    if grep -q -e 'kanban/ccc' -e 2222222 "$tmp/out"; then
      fail "kanban branch $branch gave a line"
    fi
    grep -q 'not shell-safe' "$tmp/err" || fail "no warning for kanban branch $branch"
    [ "$(grep -c . "$tmp/out")" = 3 ] || fail "branch $branch lost other lines"
  fi
done
GH_FIXTURE="$here/watch-pulls.json" GH_REFS="$here/watch-refs.json"

refused() {
  what=$1
  shift
  rm -f "$GH_ARGS"
  if sh watch.sh "$@" > "$tmp/out" 2> "$tmp/err"; then
    fail "accepted $what"
  fi
  [ ! -s "$tmp/out" ] || fail "printed lines with $what"
  [ -s "$tmp/err" ] || fail "said nothing on stderr with $what"
}

echo "watch: a failing gh call fails the run and prints no lines"
for endpoint in graphql refs compare; do
  export GH_FAIL=$endpoint
  refused "gh failing on $endpoint"
done
unset GH_FAIL

refused_early() {
  refused "$@"
  [ ! -e "$GH_ARGS" ] || fail "gh ran with $1"
}

echo "watch: bad arguments are refused before gh runs"
WATCH_REPO=''
refused_early "no repo"
WATCH_REPO=acme/widgets
refused_early "a repo with a path in it" --repo 'acme/widgets/pulls?x=1'
refused_early "an unknown argument" --since 1d
refused_early "--repo without a value" --repo

echo "ok"
