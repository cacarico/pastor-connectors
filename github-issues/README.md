# github-issues

A [pastor](https://github.com/cacarico/pastor) connector that turns GitHub
issues into tasks. Each run lists the issues of one repository that carry a
label and emits one item per issue; pastor queues a task for each item it
has not seen. When a task ends, the connector's finish command comments on
its issue with the task id, the final state, the branch and the branch's pull
request; merging that pull request closes the issue.

GitHub is reached through the `gh` CLI, so the login `gh` already has on the
head is the only credential. The connector declares no secrets and needs
nothing in `.env`. It needs pastor 0.7.0 or later, and `gh`, `jq` and a
POSIX `sh` on the head.

## Install

```bash
pastor connector install cacarico/pastor-connectors/github-issues
# or, from a checkout:
pastor connector link ./github-issues
```

## Job

```toml
# ~/.config/pastor/jobs/widgets.toml
every = "10m"

[connector]
use = "github-issues"
repo = "acme/widgets"   # required, owner/name
label = "pastor"        # default
state = "open"          # default; open, closed or all

[dispatch]
repo = "~/work/widgets"
worktree = true
branch = "pastor/issue-{{ item.key }}"
backfill = "30d"
max_tasks_per_run = 2
prompt = """
You are in a worktree of widgets on branch pastor/issue-{{ item.key }}, task {{ task.id }}.
Fix GitHub issue #{{ item.key }} by {{ item.author }}: {{ item.title }}
{{ item.url }}

{{ item.body }}

End the commit body with "Fixes #{{ item.key }}", push the branch, open a
pull request whose body says the same, and print DONE as your last line.
"""
```

Each item has `key` (the issue number, as a string), `title`, `body` (empty
when the issue has none), `url` and `author` (the GitHub login). Pull
requests are skipped even when they carry the label.

## How runs are bounded

The connector asks GitHub for issues updated at or after a point in time and
emits a cursor with the newest `updated_at` it saw; the next run starts
there. Before the first cursor exists, the bound is pastor's `since`: now
minus the job's `backfill`, which defaults to zero. Set `backfill` to how far
back the first run should look, or the job starts with an empty list and
only picks up issues touched after it was enabled.

An issue makes one task. pastor remembers the keys it has queued, so a later
edit or comment on the same issue does not queue another.

## When a task ends

pastor runs the manifest's `[finish]` command once when a task of one of the
connector's jobs ends `done` or `failed`:

```toml
# pastor-connector.toml
[finish]
command = ["sh", "finish.sh"]
```

`finish.sh` reads the task, its final state and its branch from stdin (see
"The finish command" in pastor's manual), looks for a pull request from that
branch with `gh pr list --head <branch>`, and comments on the issue:

> pastor task t-7 ended `done` on branch `pastor/issue-12`.
>
> Pull request: https://github.com/acme/widgets/pull/31

Without a pull request the comment says there is none yet; a task with no
branch gets only the first line. The machine and the task's error stay out,
since the issue may be public; `pastor task describe` has both.

It comments once per task. pastor keeps the tasks it has finished in memory
only, so after a restart it could run the command again; `finish.sh` writes
`finished-t-<id>` to the job's state dir after it comments and does nothing
for a task that has one. A failed lookup of the pull request logs a line and
comments without the link. A failed comment logs gh's error and exits 1, and
pastor emits `connector.finish_failed`; it does not retry.

`done` means the agent went idle, not that the work is good; the comment is
a prompt to look at the pull request.

### Closing the issue

The connector never closes an issue itself. The job's prompt has the agent
end its commit body with `Fixes #<issue>`, from `{{ item.key }}`, and GitHub
closes the issue when that commit lands on the default branch, however the
pull request is merged. Nothing polls for merges and no state is kept. A
pull request closed without merging leaves the issue open.

## Try it

```bash
pastor connector link ./github-issues
pastor connector run github-issues --job widgets --since 90d   # prints items, creates nothing
pastor connector unlink github-issues
sh github-issues/finish.sh --dry-run < github-issues/test/finish.json   # prints the comment, posts nothing
```

`connector run` reads the job's `[connector]` table from its file, which may
have `enabled = false`. `finish.sh --dry-run` takes the stdin pastor would
send, `test/finish.json` being a sample, and prints the comment it would post.
It still asks GitHub for the pull request, and it writes nothing to the state
dir.

## Test

```bash
make check
```

`test/run.sh` puts a fake `gh` first on `PATH` that answers `gh api` from
`test/issues.json` and `gh pr list` from `test/prs.json`, fails on request,
and records its arguments. It checks the emitted lines against
`test/expected.jsonl`, the query the connector sends, the config validation,
and the finish comment: its state, branch and link, that it is posted once,
and that a failed `gh` exits non-zero. Nothing touches the network.
