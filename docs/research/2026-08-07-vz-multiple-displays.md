# VZ multiple displays: one for a macOS guest, several for a Linux guest — but no view can show the extras

**Date:** 2026-08-07 · **Host:** M1 Max, 32 GB, macOS 27.0, Xcode 27.0 SDK

## Summary

Both graphics device types carry at most one display each, stated in their
headers and enforced by `VZVirtualMachineConfiguration.validate()`. The guest
families diverge on how many graphics *devices* one configuration may hold:

- **macOS: exactly one device with exactly one display.** Two displays on a
  `VZMacGraphicsDeviceConfiguration` fail with "Number of displays is greater
  than the configured display port count"; two such devices fail with "Number
  of graphics devices is greater than the maximum number supported" — both
  `VZErrorDomain` code 2. That "display port count" is settable by no public
  property: `maximumPortCount` exists only on
  `VZVirtioConsolePortConfigurationArray`, for console ports.
- **Linux/EFI: one scanout per device, but many devices.** Two scanouts on one
  `VZVirtioGraphicsDeviceConfiguration` fail with "More than one scanout is
  configured", while multiple single-scanout devices validate, start, and are
  visible at runtime. Counts 1 through 64 all validated — 64 is where the probe
  stopped asking, not a measured ceiling — and a 4-device VM started with
  `VZVirtualMachine.graphicsDevices` reporting four `VZVirtioGraphicsDevice`s of
  one display each.

**Presentation, not configuration, is the binding constraint.**
`VZVirtualMachineView` binds to a virtual machine — `virtualMachine`, or macOS
27's Sendable `VZVirtualMachineViewAdaptor(virtualMachine:)`, which wraps a VM
and nothing else — and offers no way to aim a view at a chosen
`VZGraphicsDevice` or `VZGraphicsDisplay`. Per-display targeting does exist
inside the framework: `automaticallyReconfiguresDisplay` is documented as
settable "on a single VZVirtualMachineView targeting a particular
VZGraphicsDisplay at a time" (`VZVirtualMachineView.h`). Choosing that target is
not public API.

Whether a second `VZVirtualMachineView` on one VM renders a second virtio device
is untested — the probe ran headless.

Consequences for Kernova: `ConfigurationBuilder`'s single-element `displays` and
`scanouts` arrays sit at the framework maximum on both counts for macOS, and at
the maximum per device but below the per-configuration allowance for Linux. A
Linux multi-display feature is reachable in the VZ configuration and blocked at
the view layer.

## Method

A standalone Objective-C probe compiled with `clang -fobjc-arc -framework
Virtualization` and ad-hoc signed with `com.apple.security.virtualization`:

1. **Validation:** `validateWithError:` over configurations varying one axis at a
   time — displays per device, devices per configuration — for both device
   types. The virtio cases used a diskless `VZGenericPlatformConfiguration` with
   a `VZEFIBootLoader` and a freshly created `VZEFIVariableStore` (validate
   rejects a nil variable store first, masking the graphics result). The mac
   cases used a `VZMacPlatformConfiguration` built from
   `VZMacOSRestoreImage.fetchLatestSupported`'s hardware model, with fresh
   auxiliary storage and machine identifier.
2. **Device-count sweep:** validation repeated for 1…64 virtio graphics devices,
   each with one 1920×1200 scanout; all accepted.
3. **Start:** the 4-device virtio configuration on a `VZVirtualMachine` with a
   private serial queue, `startWithCompletionHandler:` — completes without error
   (firmware idles with no disk), then `graphicsDevices` and each device's
   `displays` read back on that queue before stopping.
4. **View surface:** read `VZVirtualMachineView.h`, `VZGraphicsDevice.h`, and the
   `Virtualization.swiftinterface` entry for `VZVirtualMachineViewAdaptor`;
   grepped the framework headers for a display-port-count property.
