# Toolbar

How Kernova builds its `NSToolbar` items on the glass toolbar introduced in
macOS 26, and the measured platform behaviors the construction relies on
(measurements taken on macOS 27 developer beta 4). The shared item
machinery lives in `VMToolbarManager`; the clipboard button in
`ClipboardToolbarButton`. Safari's toolbar is the visual reference for this
design: independent adjacent buttons sharing glass capsules, per-item circular
hover, and a downloads-style progress bar inside the clipboard button.

## Glass-toolbar platter model (measured)

The system renders toolbar items above a layer of glass "platter" capsules
(`NSToolbarView → NSGlassContainerView → NSToolbarPlatterView`, all private —
named here for debugging orientation only; Kernova references none of them):

- A platter is a **background sibling** of the item viewers, not an ancestor —
  items draw on top of it.
- Platters are 36 pt tall at y = 8 in the 52 pt toolbar. A lone item's platter
  is a **36×36 circle**.
- **Adjacent bordered/view-backed items merge into one shared capsule
  platter.** A fixed space (`.space`) breaks the run into separate platters; an
  `NSToolbarItemGroup` always gets its own platter regardless of neighbors.
- A multi-segment group's hover highlight is capsule-shaped (the segmented
  control's treatment), not a per-segment circle.

## Item shapes Kernova uses

| Shape | Items | Treatment |
|-------|-------|-----------|
| `NSToolbarItemGroup` (segmented) | Lifecycle (play/pause/stop) | Own capsule; segment-shaped hover |
| Plain bordered image item (`makeBorderedItem`) | Suspend, Pop Out, Fullscreen, settings toggle, New VM, palette-only verbs | Circle in its own platter, or a merged capsule when adjacent; system circular hover |
| View-backed item (`ClipboardToolbarButton`) | Clipboard | Identical to the bordered items — see below |

`VMToolbarManager.defaultItemIdentifiers` places fixed spaces to choose the
default capsule clusters: [lifecycle] [Suspend] [Clipboard] [Pop Out +
Fullscreen] [settings toggle] — every standalone action in its own circle, with
only the display pair sharing a capsule.

## The clipboard button

`ClipboardToolbarButton` uses Safari's downloads-button construction — a
standard `.toolbar`-bezel `NSButton` hosting the transfer bar as a real
Auto Layout subview — so the bar is a live view (dynamic colors, no dimming
with the item image) while the item keeps the full native platter treatment.

- **The pinned 36×36 size is load-bearing.** At exactly the platter metric the
  bezel's rollover *is* the platter's circular hover — measured pixel-identical
  to a native bordered item's (#645). At any other size the rollover no longer
  matches the platter circle.
- At that size the button renders its template symbol at the same on-screen
  size as a native image-backed item's glyph, so the glyph is identical whether
  or not the bar is showing.
- Bar metrics, taken from Safari's `ToolbarDownloadsButtonProgressBar`:
  **22×6 pt capsule, horizontally centered, bottom edge 3 pt above the
  circle's rim** — fully inside the circle.
- The bar draws in `draw(_:)` with dynamic colors: opaque track grays (system
  fill colors are translucent and illegible over the glass) and an
  accent-colored fill never narrower than its round cap.

## Sidebar section and collapse

Items left of the `.sidebarTrackingSeparator` (New VM, the sidebar toggle) get
the flat sidebar-section glass treatment, not capsule platters — that's the
platform's sectioning (Mail/Notes behave the same). While the sidebar is
collapsed, New VM is removed from the toolbar and restored on expand
(`MainWindowController.syncNewVMVisibilityToSidebarState`) — Safari's New Tab
Group pattern. The mechanism is **remove/insert, not `NSToolbarItem.isHidden`**:
on the glass toolbar a hidden item's slot keeps its width (measured on macOS 27
beta 4), leaving a dead gap between the window controls and the toggle, while
removal reclaims the space. The programmatic mutations run with
`autosavesConfiguration` suspended so the saved layout never records the
collapsed state, the removal applies only while New VM actually sits in the
sidebar section, and the customize palette is always presented with the
canonical layout (New VM restored before the sheet opens, the collapse state
re-applied after it closes).

## Constraints to respect

- Item-view content outside the item's bounds is never composited on the glass
  toolbar — keep every subview inside the 36×36 circle. (`cacheDisplay`-based
  captures bypass the glass machinery and *do* show such content; verify
  toolbar rendering on screen, never from offscreen captures.)
- All shared items set `autovalidates = false`; the manager's update methods
  own enablement (autovalidation forces `isEnabled = true` and produces a
  visible flicker fighting the observation-driven writes).
- State-dependent relabeling (Pop Out ⇆ Pop In, Fullscreen ⇆ Exit Fullscreen,
  Show ⇆ Hide Settings) is guarded by label-equality checks so no-op updates
  don't trigger AppKit redraws; palette labels keep the stable factory names.
