# Design

Read this before writing UI or making a product decision: the design philosophy
and GUI guidelines that constrain both. The general engineering and product
principles are in [AGENTS.md](../AGENTS.md#principles).

## GUI Design

### General

- Match Apple's built-in app conventions and visuals (Mail, Finder, etc.) whenever possible/feasible; cross-reference Apple's documentation and published sample code before settling on an approach.
- If matching Apple's conventions would require significant effort or complexity, ask the maintainer first before proceeding.
- Use SF Symbols exclusively for icons — no custom image assets (except the app icon).

### Layout

- AppKit owns the entire view layer — `NSSplitViewController`, `NSToolbar`, `NSWindow`, and concrete `NSViewController`s render all content (no SwiftUI / `NSHostingController`).
- The creation wizard sheet is fixed-size (`WizardStyle.width`/`height`) — a new step fits the sheet rather than resizing it.

### Typography

Use `NSFont.preferredFont(forTextStyle:)` so type scales with the system setting.

- `.title2` at `.semibold` — section/page headings (`Typography.title`)
- `.headline` — important labels and step indicators (`CalloutStyle.headlineFont`)
- `.body` — primary form content (`Typography.body`)
- `.caption1` / `.caption2` — secondary text, metadata, step numbers
- monospaced `.callout` (`NSFont.monospacedSystemFont` at the `.callout` point size) — code snippets and paths (`CalloutStyle.makeCalloutCode`)

### Spacing

Set `NSStackView.spacing` from the `Spacing` token scale (`Utilities/DesignTokens.swift`):

- `Spacing.section` / `Spacing.major` — between settings-form / hero sections
- `Spacing.medium` — between grouped elements and containers
- `Spacing.standard` — default inline / row spacing
- `Spacing.small` — icon-to-label and section-header elements
- `Spacing.tight` / `Spacing.hairline` — tightly related items

### Colors

- Status mapping lives in the `StatusColor` palette (`Utilities/DesignTokens.swift`): `inactive` (stopped / agent idle), `warning` (preparing/starting/saving/restoring/installing/suspended), `running`, `pausedInMemory`, `error`.
- Use semantic `NSColor`s (`.labelColor`, `.secondaryLabelColor`, `.controlAccentColor`) — no hardcoded RGB values.
- Destructive actions: `.systemRed` foreground.

### Controls

- Grouped settings forms: build with the `GroupedFormStyle` factories (`makeGroupedFormCard`, `makeGroupedFormCardRow`, …).
- Row and toggle labels take sentence case; section headers, push-button titles, Apple UI names, and Kernova proper nouns keep Title Case.
- A section whose rows only a stopped VM can change carries the `makeGroupedFormLockHint()` header hint and dims those rows to `Alpha.disabled`; there is no page-level lock banner.
- Navigation list: source-list `NSOutlineView` (`SidebarViewController`).
- Borderless `NSButton` in lists; `.rounded` bezel for dialog actions.
- `AlertButtonRole.destructive` for delete/stop confirmations (`SheetAlert`).
- `NSProgressIndicator`: `.controlSize = .large` for major operations, `.mini` for inline status.

### Overlays

- `NSVisualEffectView` for temporary state overlays (pause, saving/restoring).
- `NSAnimationContext` cross-dissolves for overlay transitions (`animateFade`).
- Large hero icons (`NSImage.SymbolConfiguration`) centered on overlays (`VMDisplayBackingView.makePauseOverlay`).

### Cards and Containers

- Grouped cards: `GroupedFormStyle.cardFill` at `CornerRadius.card`, borderless, with hairlines inset to the label edge and bleeding to the card's trailing edge.
- A pane with no natural width of its own caps its form content at `GroupedFormStyle.columnWidth`, centered.
- Code blocks: `CalloutStyle.makeCalloutCode` — monospaced, selectable `NSTextField` for copy-worthy snippets.
