# Two Kernova instances acting on one VM

**Date:** 2026-09-23 · **Host:** M1 Max (MacBookPro18,4), 32 GB, macOS 27.0
(26A428), Xcode 27.0 · **Binary:** two copies of one Debug build of `01de59f9`,
sandboxed, each driven through its own `Contents/Helpers/kernova` ·
**Guests:** clones of a macOS 26.6.2 VM, the macOS 26.6.2 and Ubuntu Desktop
26.04 Ephemeral Mode VMs

## Virtualization locks the writable backing files for the VM's run

The VM's files are held by Virtualization's per-VM XPC service
(`com.apple.Virtualization.VirtualMachine`), not by Kernova; Kernova's own
process holds only `serial.log`. Probed from a third process while one
instance ran the VM:

| File | Opened by the XPC service | Lock a third process sees |
|---|---|---|
| `Disk.asif` | read-write | exclusive whole file: `F_GETLK` answers `F_WRLCK pid=-1`; a shared `flock` and `O_SHLOCK` open get `EAGAIN` |
| `AuxiliaryStorage` (macOS) | read-write | the same |
| `EFIVariableStore` (Linux) | read-write, and mapped | the same |
| A read-only ISO attached as USB storage, outside the bundle | read-only | shared (`F_RDLCK`); a second shared lock is granted |
| `config.json`, `HardwareModel`, `MachineIdentifier`, `serial.log` | — | none |
| `SaveFile.vzvmsave` (after a suspend) | — | none |

A suspend releases every lock: after `kernova suspend`, `Disk.asif`,
`AuxiliaryStorage` and the save file all probed unlocked while the XPC process
was still alive.

The XPC service also holds a zero-byte
`/private/var/folders/zz/…/T/AVPLocks/<sha1>.AVPLock`. The name was the same
file for one bundle whichever instance ran it, and different for a second
bundle carrying the same machine identifier.

## A second start of a running VM is refused by Virtualization

| Guest | What the second instance reported | Kernova's handling |
|---|---|---|
| macOS | `Invalid virtual machine configuration. Failed to lock auxiliary storage.` — `VZErrorDomain 2`, underlying `NSPOSIXErrorDomain 35` (`EAGAIN`) | classified as file-lock contention, retried after 0.25, 0.5, 1 and 2 s, gave up after 4.7 s; `kernova start` exit 1; VM left Stopped with no message |
| Linux | `Invalid virtual machine configuration. The boot loader is invalid.` — `VZErrorDomain 2` → `VZErrorDomain 2` → `VZErrorDomain 50002`, no POSIX error | not classified as contention: no retry, failed in 0.28 s; exit 1; VM left in Error status carrying that message |

macOS: three runs (a clone started in A then B, the same clone in B then A,
the pool VM in A then B). Linux: one run, plus a control — the refusing
instance booted the same bundle as soon as the first had stopped it.

The running instance logged nothing during any refusal, and its guest kept
running. Before Virtualization refused, each attempt in the second instance
had built its configuration, created its own vmnet shared network
(`192.168.65.0/24`, beside the first instance's `192.168.64.0/24`), opened
`serial.log` for writing, and started its vsock listeners and serial relay,
all torn down again when the attempt failed.

## Kernova's own refusals are per process

`Block duplicate machine IDs from booting`: with C1 running in A, starting
C2 — a keep-identity clone, same `MachineIdentifier` file and
`machineIdentifierData` — from A was refused (exit 5, "has the same machine
ID as “TwoInst C1”, which is active"). The same start from B booted C2, and
both guests ran together for about 80 s; Virtualization did not refuse it
either.

Each instance reads a VM's `config.json` when it first discovers the bundle
and does not read it again; a change to a file inside an existing bundle
triggers no re-read. Every configuration write replaces the whole file with
that instance's in-memory copy.

## What the other instance can do to a running VM

With one instance running the VM and the other still showing it Stopped:

| Action in the other instance | Observed |
|---|---|
| `rename` (VM stopped in both) | The other instance went on listing the old name. |
| `set memory=4` (a key refused while running) | Accepted and written. |
| then, in the running instance, `set display.autoResize=false` | `config.json` rewritten from the running instance's copy: memory back to 8 and the name back to the old one, so both earlier writes were lost. |
| `clone --new-identity` | Accepted, while the running instance refuses to clone a running VM (exit 5). The clone booted to running and took a DHCP address. |
| `snapshot take` | Accepted as a cold snapshot of disks the guest was writing. |
| `snapshot revert --yes` | Accepted. It took a checkpoint snapshot of the live disks, then swapped new `Disk.asif`, `AuxiliaryStorage` and `config.json` into the bundle. The running guest kept writing the old files, which `lsof +L1` listed with link count 0 under `Snapshots/.RestoreStaging/`. Everything it wrote from then until it was stopped went to unlinked files. |
| `delete --yes` | Accepted. The bundle moved to `~/.Trash` while the guest kept writing `~/.Trash/…/Disk.asif`; the running instance force-stopped it normally, and went on listing the VM until its next reconcile. |
| after `suspend` in A, `start` in B | B restored A's saved session and deleted `SaveFile.vzvmsave`, while A went on showing the VM Paused. A's own start was then refused by the lock and left the VM Stopped in A. |

## Ephemeral Mode across two instances

Ephemeral Mode creates no overlay: the guest runs on the bundle's own
`Disk.asif`, and the power-off in the instance that ran it clones the
baseline snapshot's files back into the bundle. The refused start in the
second instance ended without a power-off and reverted nothing. The bundle's
`Disk.asif` kept the inode the first instance was running on.

For both pool VMs, after the first instance's power-off (and for Ubuntu, a
second run and power-off from the other instance):

- every file under `Snapshots/<baseline>/` kept its inode, size, modification
  time and SHA-256, and `Snapshots/manifest.json` its SHA-256;
- the bundle's `Disk.asif`, `AuxiliaryStorage` / `EFIVariableStore` are new
  inodes whose SHA-256 equals the baseline's;
- Ubuntu's `config.json` hashes as before; macOS 26.6.2's differs only by an
  empty `portForwardingRules` array, which this build omits whenever it writes
  the file.

## C1 after the cross-instance writes

Booted once from a single instance after the revert above: it reached
running within a second and took the same DHCP address as on its first boot.
No guest-agent handshake was logged on this boot, on C1's first clean boot,
or on the untouched pool VM it was cloned from, so the agent says nothing
here. A graceful stop did not power C1 off within 120 s, and the untouched
pool VM did not power off within 150 s either. Nothing inside the guest was
examined.

## From the code, not exercised

- `VMInstance.serialSocketPath(for:)` puts each VM's serial relay socket at
  `NSTemporaryDirectory()/knv-<16 hex of the VM id>.sock`. For the sandboxed
  app that is `~/Library/Containers/app.kernova/Data/tmp`, which holds
  other `knv-*.sock` files and is shared by every copy with the bundle
  identifier. `UnixSocketListener` unlinks that path before binding and when
  it stops. The relay is only started when `serialSocketRelayEnabled`, and no VM in the
  library had it on.
- Additional internal disks are attached by the same
  `VZDiskImageStorageDeviceAttachment` loop in `ConfigurationBuilder` as the
  main disk. Only the read-only external ISO above was exercised.

## Method

1. Two copies of one build: A in DerivedData, B a `cp -R` of it
   (`codesign --verify --deep --strict` passing on both). B was launched with
   `open -j -g`, and every other action
   on either went through that copy's own `Contents/Helpers/kernova`.
2. Disposable clones of the macOS 26.6.2 pool VM: C1 (`--new-identity`) and
   C2 (`--keep-identity` of C1). C3 was A's clone of C1 while B ran it. All
   three went to the Trash afterwards.
3. Holders from `lsof` and `lsof +L1`. `lsof`'s FD column showed no lock
   character, so lock state came from a probe run as a third process. The
   probe opened each file read-only, asked `F_GETLK` for a whole-file write
   and read lock, and tried a non-blocking shared `flock(2)` and an
   `open(O_SHLOCK | O_NONBLOCK)`, releasing anything granted at once.
4. Kernova's records from
   `/usr/bin/log show --predicate 'subsystem BEGINSWITH "app.kernova"' --info --debug`,
   separated by PID.
5. Each pool VM fingerprinted — inode, size, allocated size, modification
   time and SHA-256 of every file in the bundle — before its test and after
   its power-offs.
