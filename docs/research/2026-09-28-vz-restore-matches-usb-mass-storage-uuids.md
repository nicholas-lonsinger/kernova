# A copied bundle restores its saved state unless a USB mass storage UUID changes

**Date:** 2026-09-28 · **Host:** macOS 27.0 (26A428), Kernova Debug build 940
(`d011386b`) · **Guest:** macOS 13 (installed from 13.6 `22G120`; the library
names it "macOS 13.7.8"), `shared` network · **Tracking issue:** #1318

## Summary

A suspended VM's bundle, copied with `cp -c -R` under a new UUID with only `id`
and `name` changed in `config.json`, restores its save file: 4 of 4 runs, and 2
of 2 more when the state was saved from a paused guest. The source restores its
own save file afterwards, 8 of 8.

Regenerating the ids the way `VMConfiguration.clonedForNewInstance` does splits
by device class:

- A changed virtio `blockDeviceIdentifier` restores — an additional disk's
  (`StorageDisk.id`, 2 of 2) and the path-seeded guest-agent disk's (2 of 2).
- A changed `VZUSBMassStorageDeviceConfiguration.uuid` (a removable-media id)
  fails, 4 of 4:

  ```
  The virtual machine failed to restore with error “invalid argument”. [VZErrorDomain 12; underlying: none]
  ```

  Putting the original id back restores the same save file, 1 of 1.

The VM helper logs `[com.apple.virtualization:breadcrumb] 0x8b794a15000000b2`
5.3–5.8 s after each failing attempt began and 56–112 ms before Kernova's
`Restore failed` record, and never around a successful restore. That is a
different breadcrumb from the one a changed MAC address produces
(`0xf8a9a831000000b9`,
[2026-09-23-vz-restore-requires-the-saved-mac-address.md](2026-09-23-vz-restore-requires-the-saved-mac-address.md)).
Every restore, passing or failing, logged `ctkd … computed shared secret` for the
same key id; no `ctkd` or `SecKey` refusal
([2026-09-06-vz-restore-permission-denied-sep-refusal.md](2026-09-06-vz-restore-permission-denied-sep-refusal.md))
occurred in any run.

The main bundle disk has no `blockDeviceIdentifier` at all:
`ConfigurationBuilder.configureStorageDisks` leaves it unset for the disk
`isMainBundleDisk` matches, so its bundle-path-seeded `StorageDisk.id` never
reaches VZ.

Suspend is admitted from Paused (`kernova pause` then `kernova suspend`, exit 0
both times). The resulting save file restores in the source and in a copy.

## Method

All steps use the `kernova` tool inside the build under test,
`Kernova.app/Contents/Helpers/kernova`. Nothing ran two VMs sharing a machine
identifier at once.

1. `kernova clone --id <Ephemeral Mode macOS 13 VM> --keep-identity` gives the
   source S. The clone does not carry Ephemeral Mode or snapshots.
2. Start S, wait about 60 s, `kernova suspend`, `kernova quit`.
3. With no Kernova process running, copy the bundle:

   ```
   cp -c -R VMs/<S>.kernova VMs/<NEW>.kernova
   jq --arg id <NEW> --arg n <name> '.id=$id | .name=$n' config.json
   ```

   `diff` of `jq -S` output shows only `id` and `name`. `cmp` shows
   `AuxiliaryStorage`, `HardwareModel`, `MachineIdentifier` and
   `SaveFile.vzvmsave` identical.
4. For the id variants, also edit the copy's `config.json`: a new UUID per
   `storageDisks[].id`, renaming `AdditionalDisks/<old>.asif` to
   `<new>.asif` and its `path`; and/or a new UUID per `removableMedia[].id`.
5. Relaunch, then `kernova resume --id <copy>`. A passing copy is suspended
   again before the next resume, so no two VMs holding the machine identifier
   ever run at once. Records come from a stream started before the first
   resume:

   ```
   /usr/bin/log stream --level debug --style compact --predicate 'subsystem BEGINSWITH "app.kernova" OR subsystem == "com.apple.virtualization" OR (process == "ctkd" AND eventMessage CONTAINS "shared secret") OR (subsystem == "com.apple.security" AND eventMessage CONTAINS "SecKeyCreateDecryptedData")'
   ```

   Each attempt logs `start: route=restoredSavedState` and `restoreFromSaveFile:
   attempting restore from save file`. On success
   `VirtualizationService.restoreSavedState` deletes the save file only after
   `restoreMachineStateFrom` and `resume()` both return, and a failure never
   falls back to a cold boot. So "exit 0, save file consumed" is a warm
   restore.
6. After the copies, `kernova resume` S from its own save file (E).
7. Device set for rounds 2–3. With Kernova quit and S cold, `storageDisks` is
   set to the main disk plus a 10 GB `AdditionalDisks/<id>.asif` virtio disk
   (`diskutil image create blank --format ASIF --size 10G --fs None`).
   `removableMedia` gets the bundled `KernovaMacOSAgent.dmg` entry that
   `mountGuestAgentDisk` writes. S is cold-started so the save holds both
   devices. The `ConfigurationBuilder` debug records confirm both attached.
8. Virtio guest-agent disk (C). A macOS 12.3+ guest takes the agent disk over
   USB (`GuestAgentDiskDelivery.mode`), and no pool guest is older. So
   `installedImage.version` is set to `12.0` in S (probe only;
   `lastSeenGuestOSVersion` stayed nil because the agent never connected) and
   `removableMedia` is dropped. Each boot then logs "Attached the guest agent
   disk … as a virtio block device". Its id is
   `StableID.uuid(seed: bundlePath + "\0guest-agent")`, so it differs in every
   copy.
9. Paused (D): resume S, `kernova pause`, `kernova suspend`, then steps 3 and 5.

## Results

A — plain copy (only `id`, `name` changed):

| Run | Devices in the save | `kernova resume` | Save file after |
|---|---|---|---|
| A-1 | main disk only | exit 0, running | consumed |
| A-2 | main disk only | exit 0, running | consumed |
| A-3 | + virtio disk, + USB agent media | exit 0, running | consumed |
| A-4 | + virtio disk, + USB agent media | exit 0, running | consumed |

B — ids regenerated as `clonedForNewInstance` does (A-3/A-4's save files):

| Run | Changed | `kernova resume` | Save file after |
|---|---|---|---|
| B-1 | storage-disk ids (+ file rename) | exit 0, running | consumed |
| B-4 | storage-disk ids (+ file rename) | exit 0, running | consumed |
| B-2 | removable-media id | exit 1, “invalid argument”, breadcrumb `0x8b794a15000000b2` | kept |
| B-5 | removable-media id | exit 1, “invalid argument”, breadcrumb `0x8b794a15000000b2` | kept |
| B-3 | both | exit 1, “invalid argument”, breadcrumb `0x8b794a15000000b2` | kept |
| B-6 | both | exit 1, “invalid argument”, breadcrumb `0x8b794a15000000b2` | kept |
| B-2 control | original media id put back | exit 0, running | consumed |

C — guest-agent disk attached over virtio when saved, plain copy (its
path-seeded `blockDeviceIdentifier` differs):

| Run | `kernova resume` | Save file after |
|---|---|---|
| C-1 | exit 0, running | consumed |
| C-2 | exit 0, running | consumed |

D — `kernova pause`, then `kernova suspend` (exit 0, status Suspended, save file
written), plain copy:

| Run | `kernova resume` | Save file after |
|---|---|---|
| D-1 | exit 0, running | consumed |
| D-2 | exit 0, running | consumed |

E — the source resumed from its own save file after a copy of it had restored
(the copy suspended, never running alongside):

| Run | Save file from | `kernova resume` S |
|---|---|---|
| E-1, E-2 | main disk only | exit 0 |
| E-3, E-4 | + virtio disk, + USB media | exit 0 |
| E-5, E-6 | + virtio agent disk | exit 0 |
| E-7, E-8 | saved from Paused | exit 0 |

A suspended copy holding the same machine identifier and MAC address did not
refuse the source's resume.

## What this decides

A copy of a VM's saved state restores into a bundle at a different path, under a
different VM id, from a save file taken while running or while paused. The copy
keeps every USB mass storage device's `uuid` the state was saved under
(`RemovableMediaItem.id`, measured here; a `.usbMassStorage` `StorageDisk` sets the same property from its `id` and was not measured),
and the MAC address (2026-09-23 note), or it does not keep the state. Virtio
`blockDeviceIdentifier`s are free to change.
