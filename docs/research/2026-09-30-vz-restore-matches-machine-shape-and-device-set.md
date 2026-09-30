# A VZ restore matches the machine identifier, CPU, memory, display size and device set

**Date:** 2026-09-30 · **Host:** macOS 27.0 (26A428), Kernova Debug build 947
(`b30a25d7`) · **Guests:** macOS 13 (installed from 13.6 `22G120`; the library
names it "macOS 13.7.8"), and Ubuntu Desktop 26.04 (EFI boot), both on the
`shared` network of an entitled build · **Tracking issue:** #1318

## Summary

Each row changes one thing in `config.json` (or one disk file) beside a save
file, then resumes. Every failure is the same error the earlier notes recorded:

```
The virtual machine failed to restore with error “invalid argument”. [VZErrorDomain 12; underlying: none]
```

and a no-change resume of the same save file restored after every failing row.

**Fails:**

- The machine identifier alone (`machineIdentifierData`; the bundle's
  `MachineIdentifier` file left as it was).
- CPU count; memory size.
- Display width; display height.
- The sound device removed (both directions off); an input stream added.
- The input device pair (Mac trackpad and keyboard → USB pointer and keyboard).
- The network device removed.
- A virtio disk added or removed, at the end or in the middle; a disk of a
  different capacity at a position (a 1 GB disk's file replaced with a 2 GB one,
  or the main disk swapped with an additional disk).
- A USB removable-media item added.
- The directory-sharing device added (no shares → one) or removed (one → none).
- On the Linux guest, `clipboardSharingEnabled` on, which adds a
  `VZVirtioConsoleDeviceConfiguration`.

**Restores:**

- Display PPI.
- The network attachment kind: shared → host-only, and shared → bridged
  (Automatic interface). After the host-only restore the guest held a
  host-only address within 20 s.
- Two additional virtio disks of the same capacity swapped.
- A USB removable-media item removed.
- A second share added to the macOS guest's existing directory-sharing device,
  and a share's name changed (its path pointed at a symlink named differently).
- A `.usbMassStorage` `StorageDisk`'s `id` (its `VZUSBMassStorageDeviceConfiguration.uuid`),
  on the macOS guest and on the Linux guest. A removable-media item's `uuid`
  change failed on the same build, re-checking the
  [2026-09-28 note](2026-09-28-vz-restore-matches-usb-mass-storage-uuids.md).

The VM helper logs one `[com.apple.virtualization:breadcrumb]` code per failure
class, and none around a successful restore:

| Breadcrumb | Rows |
|---|---|
| `0xdfaceb6c000003e4` | machine identifier; CPU count |
| `0x541e461d000000c9`, then `0x73d317ba000003e3` | memory size |
| `0xec3e8c4f000003e3` | display width; display height |
| `0x03904e780000008a` | sound removed; input devices; network removed; virtio disk added or removed; directory-sharing device added or removed; Linux console device added |
| `0xc21efe2c000004b2` | sound input stream added |
| `0x84b6c5ff000000b1` | disk capacity at a position |
| `0xc60b7d7400000086` | removable media added |
| `0x8b794a15000000b2` | removable-media `uuid` (as in the 2026-09-28 note) |

Every attempt after the host was unlocked logged `ctkd … computed shared secret`
before failing or passing.

**The host's lock state.** While the host console was locked
(`ioreg -n Root -d1` reporting `IOConsoleLocked` true), an unchanged resume
failed with “permission denied”, 2 of 2 — a copied save of the macOS guest and
the Linux guest's own save file in place — with the `ctkd` and `SecKey`
refusal of
[2026-09-06-vz-restore-permission-denied-sep-refusal.md](2026-09-06-vz-restore-permission-denied-sep-refusal.md)
and breadcrumb `0xd4157ee9000000a7`. `ctkd` names the key's access control:

```
ctkd [com.apple.CryptoTokenKit:sepkey] <sepk:p256(u) kid=ddbc9f68a55140af>: (com.apple.Virtualization.VirtualMachine<…>) unable to compute shared secret: error e00002e2(-536870174) ACL=<SecAccessControlRef: aku;ock(true);odel(true);osgn(true);oa(true);okd(true)>
```

`aku` is the when-unlocked, this-device-only protection class. After the host
was unlocked the same save files restored. Cold starts and suspends between the
two locked failures succeeded.

## Method

All steps use the `kernova` tool inside the build under test,
`Kernova.app/Contents/Helpers/kernova`. Nothing ran two VMs sharing a machine
identifier at once.

1. `kernova clone --id <Ephemeral Mode VM> --keep-identity` of the macOS 13 and
   the Ubuntu pool VMs gives two sources. The macOS clone's `config.json`
   `machineIdentifierData` and its bundle `MachineIdentifier` file hold the same
   identifier; `ConfigurationBuilder.configureMacOSBoot` reads the
   `config.json` field and falls back to the file only when the field is
   absent.
2. Baselines, each cold-started, run about 60 s and suspended (`kernova
   suspend`; the Linux baseline's save came from `kernova quit`):
   - **A** (macOS): main disk only, no removable media, no shares, audio output
     only, `inputDeviceMode` automatic (resolving to the Mac pair), network
     `shared`.
   - **B** (macOS): A plus two 1 GB ASIF virtio disks
     (`AdditionalDisks/<id>.asif`), one read-only removable-media DMG, one
     shared directory. The `ConfigurationBuilder` debug records confirm each
     attached.
   - **B3** (macOS): B plus a read-only DMG as a `.usbMassStorage`
     `StorageDisk`.
   - **L** (Linux): the clone as copied — a `.usbMassStorage` ISO and the main
     disk, `clipboardSharingEnabled` false.
3. With Kernova quit, each baseline's `Disk.asif`, `AuxiliaryStorage` or
   `EFIVariableStore`, `SaveFile.vzvmsave`, `config.json` and `AdditionalDisks/`
   are copied aside with `cp -c`. Before every attempt, with no Kernova process
   running, those files are copied back (`cmp` confirms the save file and
   `config.json`), so every attempt against a baseline starts from the same
   bytes and the disks always match the save.
4. One change is applied with `jq` to `config.json` (or one disk file is
   replaced), and `diff` of `jq -S` output against the baseline shows only that
   field. `kernova resume --id <clone>` relaunches the app.
5. Records come from a stream started before the first resume:

   ```
   /usr/bin/log stream --level debug --style compact --predicate 'subsystem BEGINSWITH "app.kernova" OR subsystem == "com.apple.virtualization" OR (process == "ctkd" AND eventMessage CONTAINS "shared secret") OR (subsystem == "com.apple.security" AND eventMessage CONTAINS "SecKeyCreateDecryptedData")'
   ```

   "Exit 0, save file consumed" is a warm restore, as in the 2026-09-28 note. A
   restored guest is checked 20 s later with `kernova list` and `kernova ip`,
   then `kernova stop --force --yes`.
6. After a failure, the baseline is copied back unchanged and resumed (control).
7. Run 2 of each row uses a second save of the same baseline (A2, B2, B3b, L2):
   the first save resumed, run about 40 s, and suspended again, with
   `config.json` unchanged.
8. Live snapshot: with the running clone answering `ping -i 0.5`, `kernova
   snapshot take` (`captureLiveState`: pause, save, copy the disks, resume).
   Each snapshot was later reverted to (`kernova snapshot revert
   --no-checkpoint --yes`) and resumed.

## Results

| Row | Change | `kernova resume` | Runs | Control |
|---|---|---|---|---|
| 1 | `machineIdentifierData` → a new `VZMacMachineIdentifier` | exit 1, “invalid argument”, save kept | 2 of 2 | restores, 2 of 2 |
| 2 | `cpuCount` 4 → 2 | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 2 | `memorySizeInGB` 8 → 4 | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 3 | `displayWidth` 2368 → 1920 | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 3 | `displayHeight` 1794 → 1200 | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 3 | `displayPPI` 220 → 144 | exit 0, running | 2 of 2 | — |
| 4 | `audioOutputEnabled` off (no sound device) | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 4 | `audioInputEnabled` on (input stream added) | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 5 | `inputDeviceMode` automatic (Mac) → `usb` | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 6 | `networkEnabled` false | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 6 | `networkMode` shared → hostOnly | exit 0, running; host-only address | 2 of 2 | — |
| 6 | `networkMode` shared → bridged | exit 0, running | 2 of 2 | — |
| 7 | virtio disk added (A: 1 → 2) | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 7 | virtio disk added (B: 3 → 4) | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 7 | last additional disk removed | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 7 | middle disk removed | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 7 | the two 1 GB additional disks swapped | exit 0, running | 2 of 2 | — |
| 7 | main disk and first additional disk swapped | exit 1, “invalid argument” | 1 of 1 | restores, 1 of 1 |
| 7 | second additional disk's file replaced by a 2 GB one | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 7 | main disk listed explicitly in `storageDisks` (A) | exit 0, running | 1 of 1 | — |
| 8 | removable media added (A: 0 → 1) | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 8 | removable media added (B: 1 → 2) | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 8 | removable media removed (B: 1 → 0) | exit 0, running | 2 of 2 | — |
| 8 | removable-media `id` changed (B) | exit 1, “invalid argument” | 1 of 1 | restores, 1 of 1 |
| 9 | share added (A: 0 → 1, device added) | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 9 | share added (B: 1 → 2) | exit 0, running | 2 of 2 | — |
| 9 | share renamed (path → a symlink to the same directory) | exit 0, running | 2 of 2 | — |
| 9 | share removed (B: 1 → 0, device removed) | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| 10 | Linux: `clipboardSharingEnabled` on | exit 1, “invalid argument” | 2 of 2 | restores, 2 of 2 |
| — | `.usbMassStorage` `StorageDisk` `id` changed, macOS (B3) | exit 0, running | 2 of 2 | — |
| — | `.usbMassStorage` `StorageDisk` `id` changed, Linux (L) | exit 0, running | 2 of 2 | — |

Live snapshot of a running guest:

| Run | `snapshot take` | Guest afterwards | Pings | Revert, then resume |
|---|---|---|---|---|
| 1 | exit 0, warm | Running | 120 of 120 answered; those sent during the pause were answered together when it ended, longest round trip 3.70 s, then sub-millisecond | exit 0, save consumed |
| 2 | exit 0, warm | Running | 100 of 100 answered; longest round trip 3.60 s | exit 0, save consumed |

Not measured:

- `displayHiDPI` and `displaySizesToWindow`: `ConfigurationBuilder` reads
  neither, and `applyMatchWindowBootResolution` returns without resizing when a
  save file exists, so neither changes what a resume hands VZ.
- The reverse directions of device removal — a sound, network or
  directory-sharing device present in the configuration but absent from the
  save — were not measured.
- Bridged over a named interface, and a change between two bridged interfaces.
- Hardware model and auxiliary storage (out of scope).

## What this decides

A saved state restores only into a configuration with the same machine
identifier, CPU count, memory size and display pixel dimensions, and the same
device set: the storage devices by count and by capacity at each position, the
sound streams, the input device pair, the network device's presence, the
directory-sharing device's presence, the console devices, and no added USB
removable media. A clone that carries saved state keeps the machine identifier,
or it does not keep the state. A resume also needs the host unlocked.

Free to differ from the save: display PPI, the network attachment kind, the
shares inside the macOS guest's directory-sharing device, removing USB
removable media, a `.usbMassStorage` `StorageDisk`'s `uuid`, and — with the
guest then seeing swapped contents — the order of disks of equal capacity.

A pause, save and resume leaves a running guest running, and the state it
wrote restores.
