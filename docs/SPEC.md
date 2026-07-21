# SPEC.md

Design philosophy and guidelines for Kernova.

## Code Approach

- Do not settle for workarounds or hacks. Fix root causes with proper refactors, even when the change is larger than a quick patch.
- Aggressively identify code that looks like a shortcut or band-aid. Prefer fixing it in the current scope — even when the fix is larger than the original task. File a GitHub issue only when the fix is genuinely out of scope (a different system, another change's responsibility), not as a soft landing for borderline findings.
- The bar for acting on a finding is "does this make the code genuinely better today" — a real correctness issue, an observable perf problem, a readability win. Skip findings that only defend against unreachable scenarios, hypothetical future callers, or theoretical perf concerns at current scale.
- GitHub issues serve as durable context — when a fix is deferred, the issue should capture enough detail to address it later without rediscovery.
- Prefer the simpler path first. Always attempt or plan the straightforward solution before introducing complexity through flags, intercepts, overrides, special cases, shims, or conditional branching.
- When working on window layout issues, verify that the implementation follows AppKit best practices. Cross-reference Apple documentation and well-known code examples where possible before settling on an approach.

## GUI Design

### General

- Match Apple's built-in app conventions and visuals (Mail, Finder, etc.) whenever possible/feasible.
- If matching Apple's conventions would require significant effort or complexity, ask the user first before proceeding.
- Use SF Symbols exclusively for icons — no custom image assets (except the app icon).

### Layout

- AppKit owns the entire view layer — `NSSplitViewController`, `NSToolbar`, `NSWindow`, and concrete `NSViewController`s render all content (no SwiftUI / `NSHostingController`).
- Main window: 1200×900 default, 800×500 minimum.
- Sidebar: 212–400pt width.
- Creation wizard sheet: 720×540 (`WizardStyle.width`/`height`).

### Typography

Use `NSFont.preferredFont(forTextStyle:)` so type scales with the system setting.

- `.title2` at `.semibold` — section/page headings (`WizardStyle.titleFont`)
- `.headline` — important labels and step indicators (`CalloutStyle.headlineFont`)
- `.body` — primary form content (`Typography.body`)
- `.caption1` / `.caption2` — secondary text, metadata, step numbers
- monospaced `.callout` (`NSFont.monospacedSystemFont` at the `.callout` point size) — code snippets and paths (`CalloutStyle.makeCalloutCode`)

### Spacing

Set `NSStackView.spacing` from the `Spacing` token scale (`Utilities/DesignTokens.swift`):

- `Spacing.section` (18) / `Spacing.major` (20) — between settings-form / hero sections
- `Spacing.medium` (12) — between grouped elements and containers
- `Spacing.standard` (8) — default inline / row spacing
- `Spacing.small` (6) — icon-to-label and section-header elements
- `Spacing.tight` (4) / `Spacing.hairline` (2) — tightly related items

### Colors

- Status mapping lives in the `StatusColor` palette (`Utilities/DesignTokens.swift`): `inactive` = `.secondaryLabelColor` (stopped / agent idle), `warning` = `.systemOrange` (preparing/starting/saving/restoring/installing/suspended), `running` = `.systemGreen`, `pausedInMemory` = `.systemYellow`, `error` = `.systemRed`.
- Use semantic `NSColor`s (`.labelColor`, `.secondaryLabelColor`, `.controlAccentColor`) — no hardcoded RGB values.
- Destructive actions: `.systemRed` foreground.

### Controls

- Grouped settings forms: build with the `GroupedFormStyle` factories (`makeGroupedFormCard`, `makeGroupedFormCardRow`, …).
- Navigation list: source-list `NSOutlineView` (`SidebarViewController`).
- Borderless `NSButton` in lists; `.rounded` bezel for dialog actions.
- `AlertButtonRole.destructive` for delete/stop confirmations (`SheetAlert`).
- `NSProgressIndicator`: `.controlSize = .large` for major operations, `.mini` for inline status.

### Overlays

- `NSVisualEffectView` for temporary state overlays (pause, saving/restoring).
- `NSAnimationContext` (0.25s) for overlay transitions.
- Large hero icons (52pt, `NSImage.SymbolConfiguration`) centered on overlays (`VMDisplayBackingView.makePauseOverlay`).

### Cards and Containers

- Code blocks: `CalloutStyle.makeCalloutCode` — monospaced, selectable `NSTextField` for copy-worthy snippets.
