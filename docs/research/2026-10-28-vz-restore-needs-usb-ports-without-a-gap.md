# A VZ restore fails once a USB device was removed ahead of one still attached

**Date:** 2026-10-28 · **Host:** macOS 27.2 (26B123), Xcode SDK 27.0 · **Guest:**
Fedora Workstation 44 Live (`Fedora-Workstation-Live-44-1.7.aarch64`), booted
from that ISO as a USB mass storage device · **Tracking issue:** #1738

## Summary

A live session's hot-plugged USB mass storage devices are saved with
`saveMachineStateTo(url:)` and restored with `restoreMachineStateFrom(url:)`
into a configuration whose `VZXHCIControllerConfiguration.usbDevices` names
exactly the devices attached at the save, each under the `uuid` it had. The
restore succeeds or fails by the session's hot-plug history alone:

| After boot with `[L]` | Restore configuration | Result |
|---|---|---|
| attach B | `[L, B]` | restores |
| attach A, attach B | `[L, B, A]` | restores |
| attach A, attach B, detach B | `[L, A]` | restores |
| attach A, detach A | `[L]` | restores |
| attach A, detach A, attach B | `[L, B]` | fails |
| attach A, attach B, detach A | `[L, B]` | fails |
| attach A, detach A, attach A | `[L, A]` | fails |
| attach A, detach A, attach B, detach B, attach B | `[L, B]` | fails |
| attach A, attach B, detach A, detach B, attach C | `[L, C]` | fails |
| attach A, detach A, attach B | `[L, X, B]`, X a device never attached | fails |
| attach A, detach A, attach B | `[L, A, B]` | fails |

Each failure is:

```
The virtual machine failed to restore with error “invalid argument”. [VZErrorDomain 12]
```

the error a changed USB mass storage `uuid` gives
([2026-09-28-vz-restore-matches-usb-mass-storage-uuids.md](2026-09-28-vz-restore-matches-usb-mass-storage-uuids.md)).

Every row fits one model: the devices a session starts with sit on ports 1
through n, each later attach takes the next port no device has had in the
session, a removal leaves its port empty, and a restore succeeds only when the
saved devices fill the ports from 1 with no gap. The order the configuration
lists them in does not matter. VZ documents none of this.

Kernova's live run of #1748 showed the same on a restored session: on
2026-10-28, a Fedora 44 session restored at 19:01:10, then given one hot-plug,
saved at 19:04:58 and restored at 19:05:08; a cold-booted one given attach,
detach, attach saved at 19:14:08 and failed to restore at 19:14:17. So a
restore starts the next port after the devices it restored, as a boot does.

## Method

A standalone program, ad-hoc signed with `com.apple.security.virtualization`,
builds a `VZGenericPlatformConfiguration` VM (2 CPUs, 4 GiB, EFI with its own
variable store, one `VZXHCIControllerConfiguration`) whose only device at boot
is the Fedora live ISO, `L`, as a read-only `VZUSBMassStorageDeviceConfiguration`.
A, B, C and X are 4 MiB zero-filled raw images, each attached read-only under a
fixed `uuid`.

1. Start the VM. Retry the first hot-plug every 5 s until
   `VZUSBController.attach(device:)` succeeds — it refuses with "Virtual machine
   state is invalid for attaching the given USB device" until the guest's
   firmware is up, about 5 s in.
2. Run the row's attaches and detaches through `attach(device:)` and
   `detach(device:)`, 5 s apart.
3. `pause()`, `saveMachineStateTo(url:)`, `stop()`.
4. Build a new `VZVirtualMachine` from the row's restore configuration, same
   machine identifier and variable store, and call `restoreMachineStateFrom(url:)`
   then `resume()`.

Each row ran once.
