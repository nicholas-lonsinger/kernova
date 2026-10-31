# Linux and macOS guests on a VZ USB disk's unplug and re-plug

**Date:** 2026-10-30 · **Host:** macOS 27.2 (26B123) · **Guests:** Ubuntu 26.04.1 LTS (kernel 7.0.0-38-generic, GNOME on Wayland, auto-login) and macOS 27.2 (26B123), copies of Kernova pool VMs · **Tracking issue:** #1755

## Findings

### Re-plug after a restore

In each test below, the guest was saved, restored with no USB device listed, and
resumed. A disk attached again was then mounted at its earlier mount point, on
both guests:

| Guest | Test | Attach to mount |
|---|---|---|
| Linux | A | 1.7 s |
| Linux | B | 1.7 s |
| Linux | D | 1.6 s |
| macOS | A | 1.6 s |
| macOS | B | 1.4 s |
| macOS | C | 1.8 s |
| macOS | D | 1.4 s |

The mount points were `/run/media/pbear/<label>` on Linux and `/Volumes/<label>`
on macOS. Restoring with nothing listed after a detach is a case
[the restore note](2026-10-30-vz-restore-fails-after-usb-detach.md) records as
restoring.

### Unplug while paused

In B, the disk was detached while the VM was paused and was attached again right
after the resume. The guest dropped the old mount 0.10 s (Linux) and 0.22 s
(macOS) after `resume()` returned. 30 s later each guest held one mount of the
volume, on the re-plugged disk, and was still answering SSH.

### Data

The Linux images are FAT32, which udisks mounted with the `flush` option. The
macOS images are APFS.

| Test | Disk | Guest, before the unplug | Unplug | Linux | macOS |
|---|---|---|---|---|---|
| A, B | read-only | reads a known file | running (A), paused (B) | hash matches | hash matches |
| C | read-write | writes 32 MiB and a small file; macOS runs `diskutil eject` | running | no result | both files intact |
| D | read-write | writes 32 MiB and a small file with no sync; pause 11–12 ms after the write returns | paused | both files intact | both files absent |
| E | read-write | writes 32 MiB, then `sync` | running, mounted | file intact | file intact |

**macOS D.** A copy of the image taken right after the paused unplug held
neither file. After the resume and re-plug both were still absent, and
`diskutil verifyVolume` reported the volume OK.

**Linux D.** The copy taken right after the paused unplug held both files with
their written hashes. After the resume, the kernel logged:

- `lost async page write` for logical blocks 8098 and 1;
- `FAT-fs (sda1): unable to read boot sector to mark fs as dirty`.

On re-plug it logged `Volume was not properly unmounted`. `fsck.vfat -n` then
found the dirty bit set, a wrong free-cluster count, and a boot sector that
differed from its backup.

**Linux E.** The kernel logged the same lost write for block 8098, and
`fsck.vfat -n` found the dirty bit set.

**Linux C.** C produced no result: the disk did not mount on its first attach,
and the run then hit the VM crash #1758 tracks, which a guest-initiated
power-off of a VZ USB disk causes.

### What each guest shows

**macOS** presented a DiskArbitrationAgent notification, alert style, for each
read-write disk unplugged while mounted (E and D). It presented none for the
read-only disk unplugged while mounted (A and B), and none after `diskutil eject`
(C). The unified log does not carry the notification's text.
`diskarbitrationd` added the volume to its `danglingVolumeList` in A, B, D and E
alike.

**Linux** logged the unplug in the kernel (`USB disconnect`, plus the I/O errors
above for a read-write disk). udisks logged `Cleaning up mount point … (device
8:1 no longer exists)`. The user journal, filtered for eject, mount, udisks,
gvfs, removal, USB and notification records, held nothing.

### Identity

Every VZ USB disk presents the same USB identity: vendor `0x05ac` and product
`0x1503`, "Virtual USB Mass Storage Device" by "Apple Inc.", serial string index
0.

On **Linux**:

- Two disks attached together both had `ID_SERIAL=Apple_Virtual_Disk-0:0`, and
  sysfs `serial` was empty on both.
- `/dev/disk/by-id/usb-Apple_Virtual_Disk-0:0` pointed at one disk, and its
  `-part1` link at the other disk's partition.
- The udisks Drive object path,
  `/org/freedesktop/UDisks2/drives/Apple_Virtual_Disk_Apple_Virtual_Disk_0_3a0`,
  has no per-device part.
- Only `ID_PATH` differed between the two disks, by USB port.

On **macOS**:

- `ioreg` showed `iSerialNumber = 0`, and System Information showed "Serial
  Number: Not Provided".
- The two disks differed only by `locationID` (`0x0c100000`, `0x0c200000`).
- `diskutil` reported `Removable Media: Fixed`, `Ejectable` true, and
  `Device Location: External`.

None of the identity fields read in either guest carries the VZ device's `uuid`.
Linux reported each disk as `removable=0`.

A read-only attachment reads as write-protected on both guests. Linux logged
`Write Protect is on` and mounted it `ro`; macOS reported `Media Read-Only: Yes`
and mounted it `read-only`.

## Method

The harness is the standalone program described in
[the restore-with-storage-device note](2026-10-30-vz-restore-with-usb-disk-in-storage-devices.md).
For a Linux bundle it builds a `VZGenericPlatformConfiguration` with the
bundle's machine identifier, and `VZEFIBootLoader` with the bundle's variable
store. It adds virtio graphics, a USB keyboard and pointer, a virtio console
serial port and a virtio socket device. Every `attach` creates a new
`VZUSBMassStorageDevice`, with a new `uuid`. Every restore lists no USB device.

Each guest ran in a session the harness cold-booted. The steps went over SSH as
the auto-logged-in user `pbear`.

A guest-side script polled `mount` every 100 ms for volumes labelled `KVZ*`. It
streamed each appearance and disappearance over SSH, and the host timestamped
each line on arrival, so every interval above is on the host clock and includes
up to 100 ms of polling.

The images were made on the host with `diskutil partitionDisk`:

- read-only: 64 MiB, holding a 4 MiB file of known SHA-256;
- read-write: 256 MiB;
- Linux images: MBR and FAT32;
- macOS images: GPT and APFS.

To check an image, the host made an APFS clone of it, attached the clone
read-only, ran `fsck -n` on it, mounted it read-only, and hashed its files. This
ran after the paused unplug in D and after each test's final unplug.

The tests, each run once per guest:

- **A.** Attach the read-only disk and hash its file, then detach it while
  running. Pause, save, stop, restore and resume, then attach it again and
  hash it.
- **B.** With the read-only disk mounted: pause, then detach. Save, stop,
  restore and resume, attach it again at once, and check the guest 30 s later.
- **C.** Attach a read-write disk and write 32 MiB of random data and a small
  file. macOS releases the disk with `diskutil eject` of the whole disk.
  Detach while running. Pause, save, stop, restore and resume, then attach it
  again and verify the hashes.
- **D.** Attach a read-write disk, write as in C with no sync, pause, and
  detach. Clone the image, then save, stop, restore and resume. Attach it again
  and verify.
- **E.** Attach a read-write disk, write 32 MiB, and `sync`. Detach while
  running with the disk mounted, attach it again without a restore, and verify.

The Linux and macOS logs above were read with `journalctl` and
`/usr/bin/log show`, from a guest-clock mark taken at each test's start.
