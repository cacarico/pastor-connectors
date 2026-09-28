# github-pr-reviews

A [pastor](https://github.com/cacarico/pastor) connector that turns review
findings on GitHub pull requests into tasks. Each run lists the open pull
requests of one repository and their reviews, and emits one item per review
by a matching reviewer (Copilot by default). The item carries the review's
unresolved inline comments, so a job can start an agent that fixes them on
the pull request's branch.

It also has a `[watch]` command for `pastor watch`: one line per open pull
request and one per `kanban/` branch, so an orchestrator sees reviews, CI,
merge state and branches pushed without a pull request.

GitHub is reached through the `gh` CLI, so the login `gh` already has is the
only credential. The connector declares no secrets; `.env` holds only the
repository the watch command looks at. It needs `gh`, `jq` and a POSIX `sh`,
and pastor 0.7.0 or later for `[watch]`. It has no hook.

## Install

```bash
pastor connector install cacarico/pastor-connectors/github-pr-reviews
# or, from a checkout:
pastor connector link ./github-pr-reviews
```

## Job

```toml
# ~/.config/pastor/jobs/widgets-reviews.toml
enabled = false   # start it with `pastor job enable widgets-reviews`
every = "10m"

[connector]
use = "github-pr-reviews"
repo = "acme/widgets"        # required, owner/name
reviewer = "copilot"         # default; a regex on the reviewer's login, ignoring case
only_with_findings = true    # default; skip reviews with nothing unresolved

[dispatch]
repo = "~/work/widgets"
worktree = true
branch = "pastor/review-{{ item.key }}"
backfill = "1d"
max_tasks_per_run = 2
prompt = """
You are in a worktree of widgets, task {{ task.id }}. Put it on pull request
#{{ item.pr }} ({{ item.title }}) before anything else:

    gh pr checkout {{ item.pr }}

A review left the findings below, each a comment id, a file and line, and
the comment. Review: {{ item.review_url }}

{{ item.body }}

Fix each finding that is right and say why for each one you leave. Commit,
push with a plain `git push`, and print DONE as your last line.
"""
```

pastor does not let an item name the branch a worktree is created on: an
item value in `branch` must be one path component, never the first one, so
it cannot point an agent at `main` (and head branches often hold a `/`).
The worktree gets a branch of its own, and the prompt moves it to the pull
request with `gh pr checkout`, which also sets the upstream that a plain
`git push` goes to. The prompt names the pull request by its number, never by
its branch: a branch name is chosen by whoever opened the pull request, and
an agent may paste it into a shell.

Each item has `key` (the review id, as a string), `pr` (the pull request
number), `title` (the pull request's title), `branch` (its head branch),
`head` (the head commit's sha), `review_url` and `body`. The body holds one
section per unresolved inline comment of that review:

```
## 2934017465
src/limit.rs:12
The window is never reset, so a client stays blocked forever.
```

A comment is unresolved when its review thread is not resolved. Replies in a
thread belong to other reviews and are left out. The line is the comment's
current line, or the line it was made on when the code has moved since. With
`only_with_findings = false`, a review with no unresolved comments is still
an item, with an empty body.

A pull request whose head branch holds anything but letters, digits, `/`,
`-`, `_` and `.`, starts with `-` or holds `..` makes no items; it is logged
with level `warn` and its reviews still move the cursor. Even a checked
branch is best kept out of commands: `item.pr` is a number.

## How runs are bounded

Every run reads all open pull requests, then looks only at reviews submitted
at or after a point in time, and emits a cursor with the newest review's
`submittedAt`; the next run starts there. Any reviewer's review moves the
cursor, whether or not it made an item. Before the first cursor exists, the
bound is pastor's `since`: now minus the job's `backfill`, which defaults to
zero, so without a `backfill` the first run only sees reviews that arrive
after the job was enabled.

A review makes one task. pastor remembers the keys it has queued, and
resolving threads later does not change a review's id. A fix pushed to the
branch usually brings a new review, which is a new item.

One query reads at most 100 reviews and 100 review threads per pull
request, and 50 comments per thread; these lists are not paginated. A pull
request with more makes no items, since any of its reviews could be missing
findings, and is logged with level `warn` each run. It also holds the cursor
so that nothing it has is lost: at the cursor the run started from when its
reviews were cut short, or at its first new review when its threads or
comments were. The cursor stays there until the pull request is closed;
other pull requests' reviews still make items meanwhile, and pastor does not
queue a key twice.

## Try it

```bash
pastor connector link ./github-pr-reviews
pastor connector run github-pr-reviews --job widgets-reviews --since 7d   # prints items, creates nothing
pastor connector unlink github-pr-reviews
```

`connector run` reads the job's `[connector]` table from its file, which may
have `enabled = false`, so the job above can be tried before it is enabled.

## Watch

`pastor watch` runs `watch.sh` each interval on the machine where the
watcher runs, with no job and no arguments, so the repository comes from the
connector's `.env` (`~/.config/pastor/connectors/github-pr-reviews/.env`):

```bash
WATCH_REPO=acme/widgets
```

```toml
# pastor.toml
[[watch.connector]]
name = "github-pr-reviews"
```

Each run prints the state as it is now, and the watcher prints a line only
the first time it sees it, so a line shows up when something about it
changes:

```
PR #41 branch=kanban/0e7d383e head=3f2a9c1 copilot=reviewed threads_open=2 ci=SUCCESS merge=BLOCKED
PUSHED kanban/0e7d383e sha=3f2a9c1 pr=#41
PUSHED kanban/8070c85f sha=e1e6411 pr=merged
PUSHED kanban/fe868ab9 sha=4cba06d pr=none
```

- `PR`: every open pull request. `head` is the head commit's short sha;
  `copilot` is `reviewed` once any of its last 100 reviews is by a login
  matching `copilot`, else `none`; `threads_open` counts its unresolved
  review threads (of the first 100); `ci` is the head commit's check rollup
  (`SUCCESS`, `FAILURE`, `PENDING`, ...) or `none`; `merge` is GitHub's
  merge state (`CLEAN`, `BLOCKED`, `DIRTY`, `BEHIND`, ...).
- `PUSHED`: every branch under `kanban/`. `pr` is the open pull request whose
  head it is, else `merged` when its head is already in the default branch
  (kanban branches are kept after they merge), else `none`: pushed and
  waiting for a pull request.

The shape is the one the `orchestrating-pastor-tiered` skill's `watch.sh`
printed, so its table matches these lines word for word. A pull request or
branch whose name breaks the rule for head branches above gets no line, only a note on
stderr. Asking whether a branch is in the default branch costs one API call
per branch, so a yes is kept in the connector's state dir and not asked
again. A no is asked every run, since the branch may merge.

A run that fails (a `gh` call fails, or the repository is missing or not
`owner/name`) prints no lines and exits non-zero; the watcher shows it as
`CONNECTOR github-pr-reviews failing`. Stderr goes to the run log.

To see the lines once, without a watcher:

```bash
pastor connector try github-pr-reviews watch
sh watch.sh --repo acme/widgets     # from a checkout; --repo overrides WATCH_REPO
```

## Test

```bash
make check
```

`test/run.sh` puts a fake `gh` first on `PATH` that answers `gh api graphql`
from `test/pulls.json` (two pull requests: one Copilot review with two
unresolved findings and a resolved one, one clean review) and records its
arguments, then checks the emitted lines against `test/expected.jsonl`, the
reviewer and `only_with_findings` settings, the cursor, unsafe head
branches, cut-short nested lists and the config validation.

`test/watch.sh` runs `watch.sh` against the same fake `gh`, which answers the
GraphQL query from `test/watch-pulls.json`, the `kanban/` refs from
`test/watch-refs.json` and each compare from `test/watch-compare.txt`. It
checks the lines against `test/watch-expected.txt`, the compare cache,
unsafe branch names, failing `gh` calls and bad arguments. Nothing touches
the network.
