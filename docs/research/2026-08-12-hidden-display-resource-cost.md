# Hidden VZVirtualMachineViews are free to keep attached; only shrinking the display frees memory, and only in the VM helper

**Date:** 2026-08-12 · **Host:** M1 Max, 32 GB, macOS 27.0, Xcode 27.0 SDK

## Summary

Display memory lives in each VM's own `com.apple.Virtualization.VirtualMachine`
XPC helper process, never in the app. The app is out of the frame path
entirely: 0.00–0.01% CPU in every state measured, including with a visible,
actively rendering macOS guest desktop — frames flow helper → IOSurface →
WindowServer. WindowServer itself ran 8–11% in all states, hidden views adding
nothing (hidden layers are not composited).

- **A hidden-but-attached view costs ~4 IOSurfaces / ~384 KB, app-side.** Two
  attached `VZVirtualMachineView`s held 20 IOSurfaces / 768 KB resident in the
  app; one held 16 / 384 KB. That is the entire app-side delta.
- **Detaching (`virtualMachine = nil`) frees nothing anywhere.** Within one
  helper process, hidden-attached, hidden-detached, and reattached states read
  identically once the guest settled: 192.8 MB resident IOSurface, 1123
  surfaces, 8247 MB phys_footprint. Reattach allocated nothing back because
  detach had released nothing.
- **Hot-unplugging the display is impossible.** `VZGraphicsDevice.displays` is
  `readonly, copy` (`VZGraphicsDevice.h`); displays are fixed at VM creation.
  Runtime attach/detach exists only for USB devices (`VZUSBController`).
- **A live shrink is the one lever that frees memory.**
  `VZGraphicsDisplay.reconfigure(sizeInPixels:)` on a hidden macOS 26.6 guest's
  display, 2400×1794 HiDPI → 800×600, dropped the helper's resident IOSurface
  from 194.5 MB to 66.2 MB and its phys_footprint from 8246 MB to 8212 MB — the
  paravirtual-GPU surface pool scales with display size, not just one
  framebuffer. The memory returns when the display renegotiates back.
- **The shrink cycle is graceful but guest-visible.** With
  `automaticallyReconfiguresDisplay = true`, reselecting the VM renegotiated to
  full size in under a second; a Finder window opened beyond the 800×600 area
  came back at exactly its original frame — the guest handles the cycle like a
  monitor unplug/replug. But every cycle is a display mode change the guest
  observes, twice per hide/show round trip.
- **nil-then-reattach on the same view misbehaved in no way observed.** The
  `DetailContainerViewController` doc-comment constraint concerns reassigning
  `virtualMachine` between live VMs, not clearing and restoring it.

Consequences for Kernova: the shipped design — per-VM backing views, hidden
via `isHidden` while unselected — is already resource-optimal short of a
guest-visible shrink, which trades ~34 MB of footprint per hidden Retina guest
for a mode change on every sidebar switch. Untested: Linux guest window
restoration across a shrink cycle, and guests actively animating during one.

## Method

A Debug build with two experiment toggles read from the argument domain
(`open Kernova.app --args -ExperimentDetachHiddenDisplays YES
-ExperimentShrinkHiddenDisplays YES`): the first made both hide sites in
`DetailContainerViewController.updateDisplayState()` call
`VMDisplayBackingView.detach()`; the second additionally called
`reconfigure(sizeInPixels: 800×600)` on the hidden VM's first display. The
experiment code was reverted after measurement.

1. **Guests:** Ubuntu 26.04 (1160×896) and macOS 26.6 (2400×1794 HiDPI),
   running inline simultaneously for the detach A/B; the macOS guest alone for
   the within-process attach/detach/reattach and shrink passes.
2. **Sampling:** per state, 15 × 2 s `top` samples (first since-boot sample
   dropped) over the app, every `com.apple.Virtualization.VirtualMachine`
   helper, and WindowServer; `footprint` for phys_footprint; `vmmap --summary`
   for IOSurface region totals and counts.
3. **Confound controls:** helper memory was never compared across a
   quit/relaunch — quitting save-suspends the guests and restoring makes all
   guest RAM resident, which alone moved helper footprints by gigabytes.
   Attach state was instead toggled within one live helper process via sidebar
   selection. Flag presence was verified by grepping
   `Contents/MacOS/Kernova.debug.dylib` (the app binary is a launcher stub
   holding no app code) and by the experiment's own log lines.
4. **Guest-disruption probe:** a Finder window opened in the guest extending
   beyond the 800×600 region, then a hide → shrink → reselect cycle; window
   frame compared across host-side screenshots taken immediately after
   reselection.
