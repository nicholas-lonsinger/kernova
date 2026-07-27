# SPEC.md

Read this before writing UI or making a product decision: the design philosophy
and GUI guidelines that constrain both.

## Code Approach

- Do not settle for workarounds or hacks. Fix root causes with proper refactors, even when the change is larger than a quick patch, and prefer fixing a shortcut in the current scope over deferring it.
- Prefer the simpler path first. Always attempt or plan the straightforward solution before introducing complexity through flags, intercepts, overrides, special cases, shims, or conditional branching.

Whether a review finding is worth acting on, and what a deferred issue may say, are governed by the severity bar and issue hygiene in [REVIEW.md](REVIEW.md).

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

- `.title2` at `.semibold` — section/page headings (`WizardStyle.titleFont`)
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
- Navigation list: source-list `NSOutlineView` (`SidebarViewController`).
- Borderless `NSButton` in lists; `.rounded` bezel for dialog actions.
- `AlertButtonRole.destructive` for delete/stop confirmations (`SheetAlert`).
- `NSProgressIndicator`: `.controlSize = .large` for major operations, `.mini` for inline status.

### Overlays

- `NSVisualEffectView` for temporary state overlays (pause, saving/restoring).
- `NSAnimationContext` cross-dissolves for overlay transitions (`animateFade`).
- Large hero icons (`NSImage.SymbolConfiguration`) centered on overlays (`VMDisplayBackingView.makePauseOverlay`).

### Cards and Containers

- Code blocks: `CalloutStyle.makeCalloutCode` — monospaced, selectable `NSTextField` for copy-worthy snippets.
