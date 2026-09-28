# pastor-connectors

Connectors for [pastor](https://github.com/cacarico/pastor). Each directory is one
connector; install it with `pastor connector install cacarico/pastor-connectors/<dir>`.
They need pastor 0.5.0 or later, which calls these connectors instead of plugins.

- [github-issues](github-issues/): one task per labelled issue, and a comment on
  the issue when its task is done.
- [github-pr-reviews](github-pr-reviews/): one task per pull request review by a
  matching reviewer (Copilot by default), carrying its unresolved comments,
  and `PR` and `PUSHED` lines for `pastor watch` (pastor 0.7.0 or later).
