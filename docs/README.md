# Kernova documentation

Deep-dive documentation, read on demand. The always-relevant operating guide — the principles, and the coding, documentation, review, and git rules — is [AGENTS.md](../AGENTS.md) at the repo root (loaded by AI agents every session, and the maintainer's own quick reference).

| Document | Read it when |
|----------|--------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Making a structural change — the component map: which type owns a behavior, and the seams between them |
| [DESIGN.md](DESIGN.md) | Writing UI or making product decisions — design philosophy and GUI guidelines (layout, typography, spacing, colors, controls); the general engineering/product principles are in AGENTS.md |
| [CLIPBOARD.md](CLIPBOARD.md) | Touching host↔guest copy/paste — the clipboard subsystem's principles and trade-off rules; authoritative for any clipboard work |
| [NETWORKING.md](NETWORKING.md) | Changing how a guest attaches to a network or is reached from one — exposure, entry-time refusal, IP-display, MAC-uniqueness, and network-membership principles; authoritative for networking work |
| [TOOLBAR.md](TOOLBAR.md) | Adding or changing a toolbar item — the macOS 26 glass-platter model (capsule clustering, the 36×36 metric), the constraints on view-backed items, and the sidebar section's collapse rules |
| [SANDBOX.md](SANDBOX.md) | Touching entitlements, or auditing what a build is permitted to do — the Mac App Store readiness story and launch model behind the sandbox rules in AGENTS.md |
| [VERSION-FLOORS.md](VERSION-FLOORS.md) | Choosing how to deliver something to a guest, or explaining why a feature works on one guest and not another — the guest-side capability floors and what Virtualization allows a live VM |
| [RELEASING.md](RELEASING.md) | Cutting a release — the ordered TestFlight and Developer ID steps, each naming the file that explains its mechanism |
| [research/](research/) | Dated research write-ups that ground design decisions (e.g. vsock transport throughput) |

Also at the repo root: [README.md](../README.md) (project landing page), [CONTRIBUTING.md](../CONTRIBUTING.md) (contribution policy), [LICENSE](../LICENSE), and the agent entry points ([AGENTS.md](../AGENTS.md), imported by `CLAUDE.md`). Agent-neutral project skills live in `.agents/skills/`.
