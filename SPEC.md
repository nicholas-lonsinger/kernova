# SPEC.md

Design philosophy and guidelines for Kernova.

## Code Approach

- Prefer the most standard/optimal solution, even if it means larger changes to the codebase. Don't settle for workarounds or hacks to minimize diff size.

## GUI Design

### General

- Match Apple's built-in app conventions and visuals (Mail, Finder, etc.) whenever possible/feasible.
- If matching Apple's conventions would require significant effort or complexity, ask the user first before proceeding.
- Use SF Symbols exclusively for icons — no custom image assets (except the app icon).

### Layout

- AppKit owns structural layout (`NSSplitViewController`, `NSToolbar`, `NSWindow`); SwiftUI renders content via `NSHostingController`.
- Main window: 1100×700 default, 800×500 minimum.
- Sidebar: 200–350pt width.
- Creation wizard sheet: 550×480.

### Typography

- `.title2` + `.fontWeight(.semibold)` — section/page headings
- `.headline` — important labels and step indicators
- `.body` — primary form content
- `.caption` / `.caption2` — secondary text, metadata, step numbers
- `.system(.caption, design: .monospaced)` — code snippets and paths

### Spacing

- `VStack(spacing: 24)` — between major sections
- `VStack(spacing: 12)` — between grouped elements
- `VStack(spacing: 8)` — compact grouping (icon + label)
- `VStack(spacing: 2–4)` — tightly related items
- `HStack(spacing: 8)` — standard inline spacing

### Colors

- Status mapping: `stopped` = `.secondary`, `starting`/`saving`/`restoring`/`installing` = `.orange`, `running` = `.green`, `paused` = `.yellow`, `error` = `.red`
- Use semantic system colors (`.primary`, `.secondary`, `.accentColor`) — no hardcoded RGB values.
- Destructive actions: `.red` foreground.
- Selection highlights: `accentColor` at 0.1 opacity fill, 0.3 opacity border.

### Controls

- `.formStyle(.grouped)` for settings forms.
- `.listStyle(.sidebar)` for navigation lists.
- Default button style (`.plain`) in lists; `.bordered` for dialog actions.
- `role: .destructive` for delete/stop confirmations.
- `ProgressView`: `.controlSize(.large)` for major operations, `.controlSize(.mini)` for inline status.

### Overlays

- `.ultraThinMaterial` for temporary state overlays (pause, saving/restoring).
- `.animation(.easeInOut(duration: 0.25))` for overlay transitions.
- Large hero icons (64pt) centered on overlays.

### Cards and Containers

- Selection cards: `RoundedRectangle(cornerRadius: 12)`, accent-tinted fill when selected.
- Code blocks: `.background(.quaternary)`, `cornerRadius: 4`, `padding: 8`, monospaced font.
