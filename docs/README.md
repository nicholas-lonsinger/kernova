# Kernova documentation

Deep-dive documentation, read on demand. The always-relevant operating guide — build commands, architecture summary, and the coding/testing/review/git conventions — is [AGENTS.md](../AGENTS.md) at the repo root (loaded by AI agents every session; the same file is the human contributor quick reference).

| Document | Read it when |
|----------|--------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Making structural changes — the authoritative directory structure, component map, data flow, design decisions, and test-coverage inventory |
| [SPEC.md](SPEC.md) | Writing UI or making product decisions — design philosophy and GUI guidelines (layout, typography, spacing, colors, controls) |
| [CLIPBOARD.md](CLIPBOARD.md) | Touching host↔guest copy/paste — the clipboard subsystem's principles and trade-off rules; authoritative for any clipboard work |
| [BUILD.md](BUILD.md) | Touching build machinery — git hooks and worktree setup, signing-team derivation, test-target topology, DerivedData/IDE build-state sharing, build-number derivation, guest-agent versioning, LaunchServices ghost cleanup |
| [SANDBOX.md](SANDBOX.md) | Touching entitlements, signing, app groups, or File Provider IPC — the Mac App Store readiness story and launch model behind the sandbox rules in AGENTS.md |
| [TESTING.md](TESTING.md) | Writing any test that waits on async state or needs private production state — the async-wait seams, the injected-timeout rule, and test-only exposure patterns |
| [REVIEW.md](REVIEW.md) | Filing review-debt issues or annotating findings — the full severity bar, issue format and labels, issue hygiene, `RATIONALE:` and `periphery:ignore` formats |
| [RELEASING.md](RELEASING.md) | Cutting a release — the notarized Developer ID release flow, one-time signing prerequisites, and verification checklist |
| [research/](research/) | Dated research write-ups that ground design decisions (e.g. vsock transport throughput) |

Also at the repo root: [README.md](../README.md) (project landing page), [CONTRIBUTING.md](../CONTRIBUTING.md) (contribution policy), [LICENSE](../LICENSE), and the agent entry points ([AGENTS.md](../AGENTS.md), imported by `CLAUDE.md`, pointed to by `GEMINI.md`).
