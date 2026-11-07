# pastor-connectors

A connector is a small program that pastor runs for a job: it reads a
tracker and hands back items, and pastor queues one task per new item. The
protocol is in the [Connectors](https://github.com/cacarico/pastor/blob/main/docs/manual.md#connectors)
chapter of pastor's manual. Each directory here is one connector.

## Connectors

| Id | Turns into tasks | Secret | Calls |
|---|---|---|---|
| [github-issues](github-issues/) | issues of one repo that carry a label; comments on the issue when its task ends | none | `gh`, `jq` |
| [github-pr-reviews](github-pr-reviews/) | reviews by a matching reviewer (Copilot by default), with their unresolved comments; also lines for `pastor watch` | none | `gh`, `jq` |
| [slack](slack/) | top-level messages from listed users in one channel | `SLACK_BOT_TOKEN` | `curl`, `jq` |

## Install

Install a connector with `pastor connector install cacarico/pastor-connectors/<dir>`.
pastor shows what the connector runs and asks before it installs. Add
`--yes` when stdin is not a terminal. Install needs `git`. From a
checkout, link the directory in place instead. Then describe it to see its
config keys, its secrets and which are missing.

```sh
pastor connector install cacarico/pastor-connectors/github-issues
# or, from a checkout:
pastor connector link ./github-issues
# then:
pastor connector describe github-issues
```

Run these on the machine whose `jobs/` holds the job. A connector's secrets
go in `~/.config/pastor/connectors/<id>/.env`.

## Requirements

All three connectors need pastor 0.7.0 or later. Each needs `sh` and `jq` on
the machine whose `jobs/` holds the job. The GitHub ones need `gh`, logged
in; slack needs `curl` and a bot token (its README has the Slack app steps).

## Try one before a job

Write the job file first, with `enabled = false` if it should not run yet.
`pastor connector try` runs the connector once with that file's
`[connector]` table and prints its items. It creates no tasks and saves no
cursor. `--since` sets how far back the run looks; without it, the job's
`backfill` applies.

```sh
pastor connector try github-issues --job widgets --since 1d
pastor connector try github-pr-reviews watch
```

The second line runs the `[watch]` command once and prints its lines. Each
connector's README has a job example.

## Test

Run `make check` in a connector's directory. It checks each script with
`sh -n`, then runs the tests. Fakes in `test/bin/` stand in for `gh` and
`curl`, so nothing touches the network and no login is needed. It needs
`sh` and `jq`.

```sh
cd github-issues
make check
```

## Write one

1. Copy the directory closest to what you need.
2. Follow the protocol in pastor's manual: the manifest, the JSON line on
   stdin, and the `item`, `cursor` and `log` lines on stdout.
3. Check the config in the script. The manifest can only mark a key
   `required` and describe it.
4. Write each error to stderr as well as in a `log` line. pastor drops a
   failed run's stdout, logs included. It reports the exit and the last
   stderr line, and keeps stderr in the run log.
5. Add a fake for each outside tool in `test/bin/`, and a `Makefile` whose
   `check` target runs the tests.

## Related projects

- [pastor](https://github.com/cacarico/pastor): runs coding agents on machines you own, and runs these connectors.
- [herdr](https://github.com/cacarico/herdr): the runtime that owns the panes pastor starts agents in.
- [control-room](https://github.com/cacarico/control-room): one page in the browser for the agents herdr and pastor run.
- [farmstead](https://github.com/cacarico/farmstead): a coordination layer for coding agents: contracts and messages.
