# A VZ USB pointing device's presence pins a 13+ macOS guest's scrollbars

**Date:** 2026-08-13 · **Host:** M1 Max, 32 GB, macOS 27.0 beta 5 (26A5406e) · **Guest:** macOS 26

## Summary

A macOS guest configured with both `VZMacTrackpadConfiguration` and
`VZUSBScreenCoordinatePointingDeviceConfiguration` shows permanent, legacy-width
scrollbars: the guest binds the Mac trackpad for input (per the
`VZMacTrackpadConfiguration.h` pairing guidance) but still *enumerates* the USB
device as a mouse, and the default "Show scroll bars: Automatically based on
mouse or trackpad" setting pins scrollbars visible whenever any mouse is
present. Array order does not matter — USB-first and Mac-first both pin.
Attaching only the Mac pair restores fading overlay scrollbars. Apple's headers
and docs describe only which device a guest *uses*, never the presence side
effect, and nothing documents the both-attached case beyond it.

Separately, on this host `VZVirtualMachineView.capturesSystemKeys = true`
forwards no system hot keys (⌘-Tab acts on the host) in an app build predating
every Kernova input-device change, so the capture break is host-side, not
app-side. The onset is unbracketed — beta 4 was gone before the symptom was
isolated. Nothing in the macOS 27 release notes (all betas, diffed), the
current class documentation, or the WWDC26 Virtualization session mentions any
input or system-key change; groundwater/GhostVM#157 records the same capture
failure appearing on a macOS Sequoia point release with no app change and
resolving in a later one.

## Method

Three builds of the same app, same guest VM, same host session, judged by
scrollbar persistence in the guest and by where ⌘-Tab lands with the VM view
focused:

1. Mac pair only (pre-`14e6519` build) — scrollbars fade; ⌘-Tab still host.
2. Both pairs, Mac first (`14e6519`'s arrays) — scrollbars pinned.
3. Both pairs, USB first (scratch probe) — scrollbars pinned, ruling out order.

Release-notes comparison: Apple's `macos-27-release-notes` JSON data feed
(current, beta 5) diffed against a 2026-06-23 Wayback capture of the same
endpoint, full-text searched for input/hot-key/scrollbar terms alongside the
five relevant class-documentation JSON feeds.
