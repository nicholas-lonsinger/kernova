# A VZ restore with a USB disk in `storageDevices`

**Date:** 2026-10-30 · **Host:** macOS 27.2 (26B123) · **Guest:** the macOS guest of the FB25379418 repro · **Tracking issue:** #1755

## Finding

A VM whose configuration lists a `VZUSBMassStorageDeviceConfiguration` in
`storageDevices` (S) beside another in `VZXHCIControllerConfiguration.usbDevices`
(R) saved and restored in all four cases below. Each restored VM resumed and was
`running` 15 s later.

| Case | Before the save | Restore lists | Result |
|---|---|---|---|
| Q1a | boot `[S, R]`; detach R while running | `[S]` | restores |
| Q1b | boot `[S]`; attach R; detach R | `[S]` | restores |
| Q1c | boot `[S, R]` | `[S, R]` | restores, R back in `usbDevices` |
| Q1d | boot `[S, R]`; pause; detach R while paused | `[S]` | restores |

None of these cases lists a device attached after a detach, the pattern under
which [the earlier note](2026-10-30-vz-restore-fails-after-usb-detach.md) records
restores failing.

S never appears in `usbControllers[0].usbDevices`. After a boot listing S and R
the controller held R alone (`usbDevices.count=1`), and after Q1a's restore
listing only S it held nothing.

## Method

A standalone Swift program, ad-hoc signed with
`com.apple.security.virtualization`, uses only documented Virtualization API. It
serves commands over a Unix socket and logs each command and its result with a
host timestamp. Its configuration for a macOS bundle:

- `VZMacPlatformConfiguration` with the bundle's hardware model, machine
  identifier and auxiliary storage, and `VZMacOSBootLoader`;
- 4 CPUs and 4 GiB;
- the bundle's disk as a `VZVirtioBlockDeviceConfiguration`;
- NAT networking with a fixed MAC, an entropy device, and Mac graphics,
  trackpad and keyboard;
- one `VZXHCIControllerConfiguration`.

Boot-time USB disks are read-only `VZDiskImageStorageDeviceAttachment`s. Each
gets a new `uuid` at boot: S goes in `storageDevices`, R in the controller's
`usbDevices`. `attach` builds a new `VZUSBMassStorageDevice` and calls
`VZUSBController.attach(device:)`; `detach` calls `detach(device:)`.

`restore` builds a new configuration that lists the named devices under the
`uuid` each name last had. It runs `validate()` and
`validateSaveRestoreSupport()`, then calls `restoreMachineStateFrom(url:)` on a
new `VZVirtualMachine`.

S and R are 64 MiB raw images. Each case:

1. boots, waits 60 s, and runs its steps 10 s apart (Q1d waits 5 s between
   the paused detach and the save);
2. calls `pause()`, `saveMachineStateTo(url:)` and `stop()`;
3. restores, calls `resume()`, and reads the state 15 s later.

Each case ran once.
