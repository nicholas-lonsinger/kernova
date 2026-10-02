# A VZ restore matches a USB passthrough device by its UUID, not by the hardware behind it

**Date:** 2026-10-02 · **Host:** macOS 27.0.1 (26A434), a scratch Debug build
984 of `a31a1ebc` · **Guest:** macOS 14.8.9, a keep-identity clone of the
library's macOS 14 VM · **Accessories:** a Samsung Type-C flash drive (vendor
`04e8`, product `6300`) and an HP v165w flash drive (vendor `03f0`, product
`5307`), each with a serial number · **Tracking issue:** #1433

## Summary

A save written while a `VZUSBPassthroughDevice` is attached restores:

- into a configuration that names no passthrough device, with the accessory
  still plugged in or unplugged. The guest comes back without the drive and
  macOS in the guest reports that it was not ejected properly.
- into a configuration whose `VZUSBPassthroughDeviceConfiguration` carries the
  `uuid` the attached device had when the state was saved. With the same unit
  behind it, the guest comes back still holding the drive. With a different
  product behind it — another vendor's flash drive — the restore succeeds just
  the same: VZ matches the `uuid` and checks nothing about the hardware.

It fails with the device-mismatch error the
[2026-09-30 note](2026-09-30-vz-restore-matches-machine-shape-and-device-set.md)
records:

```
The virtual machine failed to restore with error “invalid argument”. [VZErrorDomain 12; underlying: none]
```

- when the configuration names the same unit under a fresh `uuid` — breadcrumb
  `0x8b794a15000000b2`, the code a changed removable-media `uuid` logs;
- when a save written with nothing attached is restored into a configuration
  that names the unit — breadcrumb `0xc60b7d7400000086`, the code an added
  removable-media item logs.

So a passthrough device behaves like a USB removable-media item: present in the
save and absent from the configuration restores, added fails, and a device in
both must carry the saved `uuid`. That is the restore contract
`VZUSBDeviceConfiguration.uuid`'s header states: “Before restoring the virtual
machine, it should be replaced with the uuid of a previously attached device
when the virtual machine was saved.” VZ saving with a passthrough device
attached succeeded; nothing refused it.

## Method

All steps use the `kernova` tool inside the build under test. Kernova as
shipped detaches every passthrough device before writing state
(`VirtualizationService.detachUSBAccessories`) and never puts one in the
configuration (`ConfigurationBuilder`), so the build under test added two
switches read from the app's defaults, never committed:

- skip both `detachUSBAccessories` overloads, so a suspend writes state with
  the device attached;
- in `ConfigurationBuilder.assemble`, after the removable media, append a
  `VZUSBPassthroughDeviceConfiguration(device:)` for the assigned
  `AAUSBAccessory` with a named identity key, optionally setting its `uuid`.

1. `kernova clone --exact-copy` of the macOS 14 VM, cold-started.
2. **P1:** the drive offered to Kernova, `kernova usb attach` (device
   `53D74675-…`), about 15 s, then `kernova suspend` with the detach skipped.
   The save wrote; the log records the skip and `Saved state`.
3. **P0:** P1 restored with nothing in the configuration, run about 40 s with
   no device attached, then suspended.
4. With Kernova quit, each baseline's `Disk.asif`, `AuxiliaryStorage`,
   `SaveFile.vzvmsave`, `config.json` and `host-state.json` are copied aside
   with `cp -c` and copied back before every attempt (`cmp` confirms the save
   file and `config.json`). The clone carried the source's Ephemeral Mode, so
   a stop reverts its disk; the copy-back replaces that.
5. Kernova is relaunched and, for rows that need the drive, `kernova usb list`
   is polled until macOS has assigned it, so the configuration is built with
   the accessory in hand; then `kernova resume`.
6. Records come from `/usr/bin/log stream --level debug` over
   `app.kernova*`, `com.apple.virtualization` and `ctkd`. A resume that exits 0
   and consumes the save file is a restore.
7. The guest's view was read off its display by a person at the host.

## Results

| Row | Save | Configuration | Drive | `kernova resume` | Runs |
|---|---|---|---|---|---|
| 1 | P1 | no passthrough device | plugged in | exit 0, running; guest has no drive and reports it was not ejected properly | 5 of 5 |
| 2 | P1 | no passthrough device | unplugged | exit 0, running | 2 of 2 |
| 3 | P1 | the drive, fresh `uuid` | plugged in | exit 1, “invalid argument”, save kept; `0x8b794a15000000b2` | 2 of 2 |
| 4 | P1 | the drive, the saved `uuid` | plugged in | exit 0, running; guest shows the drive | 2 of 2 |
| 5 | P1 | the HP drive, the Samsung's saved `uuid` | HP plugged in, Samsung unplugged | exit 0, running; guest force-stopped within 20 s | 2 of 2 |
| 6 | P0 | the drive, fresh `uuid` | plugged in | exit 1, “invalid argument”, save kept; `0xc60b7d7400000086` | 2 of 2 |
| — | P0 | no passthrough device | plugged in | exit 0, running (control) | 2 of 2 |

Every failure was followed by a restore of the same baseline with no
passthrough device in the configuration, which succeeded.

Not measured:

- What the guest does with a different device restored under the saved
  `uuid`: it was force-stopped at once rather than left holding a drive whose
  mounted volume it believed was another's. A second unit of the same model.
- A Linux guest.
- A warm capture (`kernova snapshot take`) with the device attached; it writes
  state through the same `saveMachineState` call as a suspend.

## What this decides

A saved state never fails to restore because of a passthrough device it holds,
as long as the configuration either leaves that device out or names it with
its saved `uuid`. Left out, the guest loses the device on resume exactly as if
it had been unplugged while running. Named with the saved `uuid`, the guest
keeps it — and since VZ checks only the `uuid`, which hardware stands behind it
is the caller's to get right: only the unit attached at save time may carry
that `uuid` back.
