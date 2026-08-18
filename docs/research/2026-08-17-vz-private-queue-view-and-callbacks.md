# VZVirtualMachineView drives a VM on a private serial queue, and VZ keeps delivering while main is blocked

**Date:** 2026-08-17 · **Host:** M1 Max, 32 GB, macOS 27.0, Xcode 27.0 SDK, built against deployment target 26.0

## Summary

A `VZVirtualMachine` created with `init(configuration:queue:)` on an app-owned
serial queue drives a `VZVirtualMachineView` normally. A Debian 13 installer
booted through EFI rendered GRUB into the view, and arrow keys sent to the
window moved the GRUB selection — so both framebuffer presentation and the
view's keyboard forwarding cross from the main-thread view to a VM living on
another queue. Setting `view.virtualMachine = nil` and re-assigning the same VM,
both from main, left the guest running and rendering.

**Every VZ-delivered callback arrived on the VM's queue and none needed main.**
Observed there: `start`'s completion handler, `VZVirtualMachineDelegate.guestDidStop`,
and both `VZGraphicsDisplayObserver` reconfiguration callbacks.

**A VZ round-trip completed while the main thread was hard-blocked.** With main
inside a 15-second `Thread.sleep`, `VZGraphicsDisplay.reconfigure(sizeInPixels:)`
issued on the VM queue produced `displayDidBeginReconfiguration` immediately and
`displayDidEndReconfiguration` 0.8 s later — a completion the guest has to
answer for. A once-a-second `vm.state` read on the VM queue kept its cadence
across the whole block.

## API surface

- `init(configuration:queue:)` is the designated initializer and dates to macOS
  11.0 — running a VM on an app-owned queue is as old as the framework. The
  no-queue initializer is documented as using the main queue, so main-queue
  isolation is that initializer's default rather than a framework requirement.
- `VZVirtualMachine.queue` (macOS 26.0) reads that queue back, and is
  `NS_SWIFT_NONISOLATED` so it is legible from any queue or actor. Its
  documentation states the rule the rest of the surface follows: "Other
  properties or function calls on VZVirtualMachine must happen on this queue.
  The framework also invokes any completion handlers from asynchronous
  functions on this queue."
- `VZVirtualMachineViewAdaptor` (macOS 27.0) is Apple's Sendable hand-off for
  exactly this arrangement — its documented purpose is that "`VZVirtualMachine`
  operates on a specific dispatch queue and is not `Sendable`", so assigning one
  to `VZVirtualMachineView.virtualMachine` across an isolation boundary is a
  compile error. It carries a VM and nothing else.
- Below 27.0 the same hand-off is written with `nonisolated(unsafe)`:
  `VZVirtualMachineView.virtualMachine` is `@MainActor @preconcurrency`, so the
  restriction is Swift's, not the framework's.
- `VZGraphicsDisplayObserver`'s header names the queue directly — both callbacks
  are documented as "invoked on the virtual machine's queue".

Nothing in `VZVirtualMachineView.h` or its documentation constrains which queue
the displayed VM was created with.

## Modelling the queue in Swift 6

A per-instance `actor` whose `unownedExecutor` is a `DispatchSerialQueue`
compiles under `-swift-version 6 -strict-concurrency=complete` against
deployment target 26.0, and `assumeIsolated` on it succeeds from a `nonisolated`
function called on that queue — the `MainActor.assumeIsolated` bridge has a
direct counterpart for a queue the app owns. This gives one isolation domain per
VM rather than the single domain a `@globalActor` would impose.

```swift
actor VMSession {
    nonisolated let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }
}
```

## Method

A standalone AppKit app in one Swift file, compiled with `swiftc -swift-version 5
-target arm64-apple-macos26.0` and ad-hoc signed with
`com.apple.security.virtualization`, holding a full-window
`VZVirtualMachineView`:

1. A diskless-EFI `VZGenericPlatformConfiguration` with a freshly created
   `VZEFIVariableStore`, one 1280×800 `VZVirtioGraphicsScanoutConfiguration`, a
   `VZUSBKeyboardConfiguration`, a `VZUSBScreenCoordinatePointingDeviceConfiguration`,
   a NAT network device, and `debian-13.6.0-arm64-netinst.iso` attached read-only
   as `VZUSBMassStorageDeviceConfiguration` — the firmware stops the VM within a
   second with no bootable device, so the ISO is what keeps a guest up long
   enough to observe.
2. The VM built inside `vmQueue.sync`, `vm.queue === vmQueue` asserted, delegate
   assigned there; `view.virtualMachine` assigned from main; `start` issued on
   the VM queue.
3. Every log line stamped with `Thread.isMainThread` and a
   `DispatchSpecificKey` probe for the VM queue, so each callback's queue is
   recorded rather than inferred.
4. Input driven with `osascript -e 'tell application "System Events" to key code 125'`
   twice, with `screencapture` before and after — the GRUB selection moved from
   "Install" to "Advanced options ...".
5. `Thread.sleep(forTimeInterval: 15)` on main, with the display reconfigure
   scheduled on the VM queue 3 s into it.
6. The isolation model checked separately, as a Swift 6 file compiled with
   `-strict-concurrency=complete` that awaits into the actor from a detached
   task and then calls `assumeIsolated` from `queue.async`.

Nothing was logged by the framework about queue misuse on any path.
