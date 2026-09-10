# Toolbar

Read this before adding or changing an `NSToolbar` item: the behaviors of the
glass toolbar introduced in macOS 26 that toolbar code has to satisfy
(measured on macOS 27.0 26A428). Safari is the visual reference —
independent adjacent buttons sharing glass capsules, per-item circular hover,
a downloads-style progress bar inside a button.

## Glass-toolbar platter model (measured)

The system renders toolbar items inside glass "platter" capsules
(`NSToolbarView → NSGlassContainerView → NSToolbarPlatterView →
NSGlassEffectView → … → NSToolbarItemViewer`, all private — named here for
debugging orientation only; Kernova references none of them):

- A platter is an **ancestor** of the item viewers it holds; only `.space` and
  `.flexibleSpace` viewers sit outside any platter.
- Platters are 36 pt tall at y = 8 in the 52 pt toolbar, with fully rounded
  ends. A lone item's platter is a **36-pt circle**; its width tracks the
  item's content, so a wide symbol widens it by a fraction of a point.
- **Adjacent bordered/view-backed items merge into one shared capsule
  platter.** A fixed space (`.space`) breaks the run into separate platters; an
  `NSToolbarItemGroup` always gets its own platter regardless of neighbors.
- A multi-segment group's hover highlight is **per segment**, each a capsule
  (the segmented control's treatment) rather than a circle.

## View-backed items

A view-backed item can be made indistinguishable from a native bordered one —
Safari's downloads button is the construction, a standard `.toolbar`-bezel
`NSButton` hosting the progress bar as a real Auto Layout subview, so the bar
stays a live view while the item keeps the platter treatment
(`ClipboardToolbarButton`). What that costs:

- **The pinned 36×36 size is load-bearing.** At exactly the platter metric the
  bezel's rollover *is* the platter's circular hover — measured pixel-identical
  to a native bordered item's. At any other size the rollover no longer matches
  the platter circle.
- **A decorative subview must return `nil` from `hitTest`.** Otherwise it
  swallows clicks over its own area — the 22×6 pt transfer bar takes the bottom
  of the circle — and the platter stops behaving as one button.
- **No `menuFormRepresentation` is needed.** The overflow-menu ("»") entry
  AppKit synthesizes for a view-backed item takes the item's label and the
  hosted button's image, and fires the button's action — a nil-target action
  travels the responder chain from there like a bordered item's.
- Bar metrics, taken from Safari's `ToolbarDownloadsButtonProgressBar`:
  **22×6 pt capsule, horizontally centered, bottom edge 3 pt above the
  circle's rim** — fully inside the circle.
- **Draw with opaque colors.** System fill colors are translucent and illegible
  over the glass.

## Sidebar section and collapse

Items left of the `.sidebarTrackingSeparator` get the same circular platters
as the content section; only the strip behind them takes the sidebar's tone.

To take an item out of that section while the sidebar is collapsed
(`MainWindowController.applyNewVMVisibility(in:)`), **remove and
re-insert it — never `NSToolbarItem.isHidden`**: the hidden item's viewer does
leave the hierarchy, but the section's leading `.flexibleSpace`, zero-width
while the item is visible, materializes in the item's slot instead of
collapsing (44 pt, measured on macOS 27.0 26A428), leaving a dead gap between
the window controls and the toggle; removal reclaims the space. With the
sidebar expanded the flexible space absorbs the item either way. Constraints
follow:

- **Remove with `autosavesConfiguration` suspended, restore with autosave live.**
  A collapsed toolbar is a transient presentation, not a customization, so it
  must never reach the saved layout; the restore, by contrast, writes back the
  user's canonical layout and *heals* a configuration that some other autosave
  captured mid-collapse.
- **Mirror the removal into a preference**
  (`AppPreferences.mainToolbarNewVMCollapseIndex`). Suspending autosave around
  our own mutation does not stop an autosave triggered by anything *else* while
  the item is out (View ▸ Hide Toolbar, a display-mode change) from persisting
  the item-less list. The mirrored index is what lets the next launch tell that
  removal apart from a deliberate customization removal
  (`adoptPersistedNewVMRemoval`); without it the item is stranded until Restore
  Default Set. Remember the index rather than recomputing it from a neighbor's
  position — the item is user-movable within the section, so anchoring the
  reinsert to a neighbor silently reorders the user's layout.
- **Present the customize palette with the canonical layout** — restore the item
  before the sheet opens, re-apply the collapse after it closes.

## Constraints to respect

- Item-view content outside the item's bounds is never composited on the glass
  toolbar — keep every subview inside the 36×36 circle. (`cacheDisplay`-based
  captures bypass the glass machinery and *do* show such content; verify
  toolbar rendering on screen, never from offscreen captures.)
- Set `autovalidates = false` on any item whose enablement is driven by
  observation — autovalidation, which runs off UI events, forces
  `isEnabled = true` and flickers against those writes; an explicit
  `validateVisibleItems()` forces it regardless of `autovalidates`.
- Guard state-dependent relabeling (Pop Out ⇆ Pop In, Fullscreen ⇆ Exit
  Fullscreen) with a label-equality check so no-op updates don't trigger AppKit
  redraws. Palette labels keep the stable factory names.
