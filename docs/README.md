# Kernova documentation

Deep-dive documentation, read on demand. The always-relevant operating guide — the principles, and the coding, documentation, review, and git rules — is [AGENTS.md](../AGENTS.md) at the repo root (loaded by AI agents every session, and the maintainer's own quick reference).

| Document | Read it when |
|----------|--------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Making a structural change — the component map: which type owns a behavior, and the seams between them |
| [CLIPBOARD.md](CLIPBOARD.md) | Designing or extending host↔guest copy/paste — the two rules every clipboard design is held to: no Kernova-imposed size bound, and pay on consume |
| [NETWORKING.md](NETWORKING.md) | Changing how a guest attaches to a network or is reached from one — exposure, entry-time refusal, IP-display, MAC-uniqueness, and network-membership principles; authoritative for networking work |
| [RELEASING.md](RELEASING.md) | Cutting a release — the ordered TestFlight and Developer ID steps, each naming the file that explains its mechanism |
| [research/](research/) | Dated research write-ups that ground design decisions (e.g. vsock transport throughput) |

Writing UI has no doc of its own: the tokens and atom factories carry their contracts in their `///` — `Kernova/Utilities/DesignTokens.swift` (spacing, radii, alpha, status colors, type), `Kernova/Views/Shared/GroupedFormStyle.swift` (grouped-form cards, rows, lock hints, banners, scrolling), `Kernova/Views/Detail/CalloutStyle.swift` (popover rows), `Kernova/Views/Creation/WizardStyle.swift` (the creation wizard), and `Kernova/Utilities/SheetAlert.swift` (confirmation alerts).

Also at the repo root: [README.md](../README.md) (project landing page), [CONTRIBUTING.md](../CONTRIBUTING.md) (contribution policy), [LICENSE](../LICENSE), and the agent entry points ([AGENTS.md](../AGENTS.md), imported by `CLAUDE.md`). Agent-neutral project skills live in `.agents/skills/`.
