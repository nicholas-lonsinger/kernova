@AGENTS.md

## Cloud sessions

A cloud session's GitHub proxy refuses GraphQL, so `gh pr` and `gh issue` subcommands fail there ([Claude Code docs: GitHub proxy](https://code.claude.com/docs/en/cloud-environments#github-proxy)); the same operations go through `gh api` REST.
The REST merge, `gh api -X PUT repos/{owner}/{repo}/pulls/<N>/merge -f merge_method=squash -f commit_message=…`, merges at once rather than queueing, so it runs only once the PR head's `tests` status is green. The VM has no Xcode, so neither `make test` nor `make lint` runs there; label the PR `ci` with `gh api repos/{owner}/{repo}/issues/<N>/labels -f 'labels[]=ci'`.
