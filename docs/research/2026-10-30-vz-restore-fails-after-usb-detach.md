# A VZ restore fails after a USB detach

**Date:** 2026-10-30 · **Hosts:** macOS 26.7.2 (25G332) and 27.2 (26B123) ·
**Apple:** FB25379418 · **Tracking issue:** #1755

## Finding

A VM hot-plugs `VZUSBMassStorageDevice`s with `VZUSBController.attach(device:)`
and `detach(device:)`, is saved with `saveMachineStateTo(url:)`, and is restored
with `restoreMachineStateFrom(url:)` into a new `VZVirtualMachine` whose
`VZXHCIControllerConfiguration.usbDevices` lists exactly the devices attached at
the save, each under its saved `uuid`. In every run below, the restore failed
exactly when it listed a hot-plugged device attached later in the VM instance's
session than a hot-plugged device detached before the save. The failure is

```
The virtual machine failed to restore with error “invalid argument”. [VZErrorDomain 12]
```

and `validate()` and `validateSaveRestoreSupport()` both pass beforehand.

These restore:

- A restore that lists no hot-plugged device, whatever was attached or detached.
  The device is absent afterwards.
- A restore whose listed devices were all attached before any detach in the
  session.
- A detach while the VM is paused. On 27.2 it completed in 3–6 ms, and the save
  and a restore listing nothing succeeded (P1–P4, read-only and read-write).

Each restored VM is a new instance whose history starts clean: after a restore
listing nothing, a device attached in the restored VM saves and restores listed
(26.7.2: V5, V6; 27.2: RW5, P3).

Inside a macOS 26 guest, `ioreg -p IOUSB` before and after a detach and
re-attach showed the same `locationID` (0x0F100000) and USB Address (1) — the
guest-visible port did not change (maintainer, 2026-10-29).

Apple's macOS 27 release notes: "Fixed: A virtual machine might crash during
restore if a USB mass storage device was hot-plugged before the virtual machine
was saved but is not attached during the restore. (177528319)"

## Fedora guest, 2026-10-28, host 27.2

A standalone program, ad-hoc signed with `com.apple.security.virtualization`,
builds a `VZGenericPlatformConfiguration` VM (2 CPUs, 4 GiB, EFI with its own
variable store, one `VZXHCIControllerConfiguration`) whose only device at boot
is the Fedora Workstation 44 Live ISO (`Fedora-Workstation-Live-44-1.7.aarch64`),
`L`, as a read-only USB mass storage device. A, B, C and X are 4 MiB zero-filled
raw images, attached read-only under fixed `uuid`s.

1. Start the VM. Retry the first attach every 5 s until it succeeds; it refuses
   with "Virtual machine state is invalid for attaching the given USB device"
   until about 5 s in.
2. Run the row's attaches and detaches 5 s apart.
3. `pause()`, `saveMachineStateTo(url:)`, `stop()`.
4. Build a new `VZVirtualMachine` from the row's restore configuration, with the
   same machine identifier and variable store, then `restoreMachineStateFrom(url:)`
   and `resume()`.

Each row ran once.

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
| attach A, detach A, attach B | `[L, X, B]`, X never attached | fails |
| attach A, detach A, attach B | `[L, A, B]` | fails |

Kernova's live run of #1748 the same day, on a Fedora 44 VM: a session restored
at 19:01:10, given one hot-plug, saved at 19:04:58 and restored at 19:05:08. A
cold-booted session given attach, detach, attach saved at 19:14:08 and failed to
restore at 19:14:17.

## macOS guest, standalone repro, 26.7.2 and 27.2

The repro attached to FB25379418 uses only documented API. It cold-boots a
macOS 26.6.2 (25G83) guest, waits 120 s, runs the steps about 15 s apart on two
8 MB FAT16 images, pauses, saves, stops, and restores into a new
`VZVirtualMachine`. "+X" attaches a new device for image X, "-X" detaches it,
"P" pauses.

| Before the save | Restore lists | 26.7.2 | 27.2 |
|---|---|---|---|
| nothing | none | restores (R0) | restores (R0) |
| +A | A | restores (R1) | restores (R1; RW1 read-write) |
| +A, +B | A, B | — | restores (D1) |
| +A, -A, +B | B | fails (R2) | fails (R2; RW2 read-write; M1, M2 mixed) |
| +A, +B, -A | B | fails (D2) | fails (D2; RW3 read-write) |
| +A, -A, +A (new device) | A | fails (R4) | fails (R4) |
| +A, -A, re-attach the same device object | A | fails (V1) | — |
| +A, -A, +B | A's `uuid`, B | fails (V4) | fails (D3) |
| +A, -A, +B | none | restores (R3) | restores (R3; RW4 read-write) |
| +A, -A, +B, -B | none | — | restores (R6) |
| +A, P, -A | none | — | restores (P1; P4 read-write) |
