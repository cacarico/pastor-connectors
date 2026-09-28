# pastor-connectors

Connectors for [pastor](https://github.com/cacarico/pastor). Each directory is one
connector; install it with `pastor connector install cacarico/pastor-connectors/<dir>`.
They need pastor 0.5.0 or later, which calls these connectors instead of plugins;
github-issues needs 0.7.0, which runs its finish command.

- [github-issues](github-issues/): one task per labelled issue, and a comment on
  the issue with the branch and pull request when its task ends.
- [github-pr-reviews](github-pr-reviews/): one task per pull request review by a
  matching reviewer (Copilot by default), carrying its unresolved comments.
