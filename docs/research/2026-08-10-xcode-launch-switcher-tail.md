# Xcode-launched apps that morph `.accessory` → `.regular` late land at the ⌘-Tab tail

**Date:** 2026-08-10 · **Host:** M1 Max, 32 GB, macOS 27.0, Xcode 27.0 beta

## Summary

A process spawned by Xcode's Run (debugger-traced) that starts `.accessory` and
morphs to `.regular` gets its Dock app-switcher entry created **at the tail**,
and no programmatic activation — `NSApp.activate(ignoringOtherApps: true)`,
delayed `deactivate()`/`activate()` cycles, with or without a gap — ever
promotes it, even when the activation demonstrably succeeds (the app becomes
frontmost). One *user-driven* switch to the app (⌘-Tab onto it, click) promotes
it and heals the run permanently.

The trigger is the morph landing **outside the launch-checkin window**:

| Variant (all launched via Xcode Run) | Switcher entry |
|---|---|
| `.regular` from `main()` (no morph) | correct |
| morph ~40 ms after checkin, single LS registration | correct — with status item, app bundle, and App Sandbox each added |
| morph ~40 ms after checkin, 4 LS registrations of the bundle ID | tail |
| morph 2.5 s after checkin, single LS registration | tail |

Kernova's morph lands ~2.2 s after checkin (VM library load precedes
`applicationDidFinishLaunching`), which put every Xcode launch in the failing
row. Duplicate registrations (stale DerivedData arenas, periphery caches, a
Trash copy — six for `app.kernova` when found) independently push even a fast
morph into the failure, presumably by delaying identity resolution; cleaning
them (`lsregister -u <path>`) restored the fast-morph repro immediately, no
Dock restart needed, but did not save the late morph.

The same binary launched any non-traced way — `open`, direct exec, plain
`lldb -b -o run` — orders correctly every time, so end-user launch paths never
hit this. Kernova sidesteps it for the dev loop by skipping the `.accessory`
demote when `P_TRACED` is set (`AppDelegate.main()`).

## Method

Repro app: minimal AppKit `main.swift` (scratch SPM package, then a scratch
`.xcodeproj` for the bundle/sandbox variants) that optionally
`setActivationPolicy(.accessory)` before `run()`, then in
`applicationDidFinishLaunching` — optionally after a delay — sets `.regular`,
shows a window, and activates, mirroring `summonUserInterface`.

Switcher-order probe, no HUD screenshots needed: seed the MRU order by
activating two known apps (Mail, then Finder), click Run in Xcode, wait for
the repro app to self-activate, activate Finder, then send one ⌘-Tab and read
`lsappinfo front`. A correctly-placed repro app is second in MRU, so ⌘-Tab
lands on it; a tail entry makes ⌘-Tab land on the third app (Xcode) instead.
Note `lsappinfo visibleProcessList` does **not** expose the defect — the
broken entry still lists in activation order — so only the behavioral probe
discriminates.
