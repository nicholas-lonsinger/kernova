# macOS 12 routes to the Extensions pane by bundle path, not by pane id

**Date:** 2026-08-03 · **Host:** M1 Max, 32 GB, macOS 27.0 · **Guest:** macOS 12.7.6, Kernova library VM, 4 vCPU / 8 GB

## Summary

On macOS 12, `NSWorkspace.open` of a
`x-apple.systempreferences:com.apple.preferences.extensions` URL launches
System Preferences at the main grid and returns `true`. The pane id is correct —
it is the `CFBundleIdentifier` of `/System/Library/PreferencePanes/Extensions.prefPane` —
and it still does not route, with or without a query anchor. Because the scheme
is claimed by System Preferences, the `true` return says only that the app
opened, so an ordered candidate list can never fall through past one of these
URLs.

Opening the pane bundle itself — `NSWorkspace.open` of
`file:///System/Library/PreferencePanes/Extensions.prefPane` — does route,
whether System Preferences is closed or already showing another pane. It lands
on Extensions with the **Added Extensions** category selected, which is where a
File Provider extension's enablement checkbox appears (Monterey's Extensions
sidebar has no File Providers category). The selection is not sticky: it lands
on Added Extensions even when the previous visit left another category chosen.

## Method

Guest agent 0.53.0 installed on the guest, its File Provider domain registered
and awaiting the user toggle. Each candidate was opened from the guest's
Terminal after `killall "System Preferences"`, and the resulting window read off
the VM display:

1. `x-apple.systempreferences:com.apple.preferences.extensions` → main grid.
2. `x-apple.systempreferences:com.apple.preferences.extensions?extensionPointIdentifier=com.apple.fileprovider-nonui`
   (the anchor form that works on 13+) → main grid.
3. `file:///System/Library/PreferencePanes/Extensions.prefPane` → Extensions,
   Added Extensions selected, listing the agent's extension with its checkbox
   unchecked.
4. Candidate 3 repeated after clicking the Share Menu category → Added
   Extensions again; and repeated without the `killall`, from a window showing
   Sound → Extensions again.

`defaults read /System/Library/PreferencePanes/Extensions.prefPane/Contents/Info CFBundleIdentifier`
returned `com.apple.preferences.extensions`, confirming candidate 1 named the
pane correctly.
