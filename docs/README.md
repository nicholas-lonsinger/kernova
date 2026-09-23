# Kernova documentation

Deep-dive documentation, read on demand; [AGENTS.md](../AGENTS.md) at the repo root is the operating guide.

| Document | Read it when |
|----------|--------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Making a structural change — the component map: which type owns a behavior, and the seams between them |
| [CLIPBOARD.md](CLIPBOARD.md) | Designing or extending host↔guest copy/paste — the two rules every clipboard design is held to: no Kernova-imposed size bound, and pay on consume |
| [LIVE-VERIFICATION.md](LIVE-VERIFICATION.md) | Checking a change in the running app — against a guest, or through App Intents from Spotlight and Shortcuts |
| [NETWORKING.md](NETWORKING.md) | Changing how a guest attaches to a network or is reached from one — the maintainer's sign-off on each new mechanism, and the exposure, entry-time refusal, IP-display, MAC-uniqueness, and network-membership principles |
| [RELEASING.md](RELEASING.md) | Cutting a release — the ordered TestFlight and Developer ID steps, each naming the file that explains its mechanism |
| [research/](research/) | Dated research write-ups that ground design decisions |

Writing UI has no doc of its own: the tokens and atom factories carry their contracts in their `///` — `Kernova/Utilities/DesignTokens.swift` (spacing, radii, alpha, status colors, type), `Kernova/Views/Shared/GroupedFormStyle.swift` (grouped-form cards, rows, lock hints, banners, scrolling), `Kernova/Views/Detail/CalloutStyle.swift` (popover rows), `Kernova/Views/Creation/WizardStyle.swift` (the creation wizard), and `Kernova/Utilities/SheetAlert.swift` (confirmation alerts).
