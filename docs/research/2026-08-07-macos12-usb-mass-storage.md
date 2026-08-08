# macOS guests bind a driver to a VZ USB mass storage device only from 12.3

**Date:** 2026-08-07 · **Host:** M1 Max, 32 GB, macOS 27.0 · **Guests:** macOS 12.0.1 and 12.7.6, Kernova library VMs, 4 vCPU / 8 GB

## Summary

A `VZUSBMassStorageDeviceConfiguration` reaches a macOS 12.0.1 guest intact —
the device enumerates, configures, and publishes an `IOUSBHostInterface` node
with correct Bulk-Only Transport descriptors — and then nothing claims it. The
matching stops there because `IOUSBMassStorageDriver.kext` is absent from that
guest's boot kernel collection: since Big Sur only a KC-resident kext has
personalities in the kernel's matching catalogue, and the kext's presence in
`/System/Library/Extensions` buys nothing. On 12.7.6 the same device grows the
full `IOUSBMassStorageInterfaceNub → IOUSBMassStorageDriver → SCSI → IOMedia`
stack and mounts.

The maintainer placed the boundary by hand: 12.2.1 fails, 12.3 works. Every
macOS guest below 12.3 therefore needs its media on another bus, and a virtio
block device carrying the same image mounts on 12.0.1.

This is not a Kernova-side descriptor problem, and no host-side change can fix
it — the guest kernel simply holds no personality that matches class 8.

## Method

Both guests ran the same Kernova build, with the same
`Resources/KernovaMacOSAgent.dmg` attached through the same
`USBDeviceService.attach` call, and were probed from their own Terminal.

1. `ioreg -p IOUSB -l` — on both guests the device appears with
   `kUSBCurrentConfiguration = 1` and an interface descriptor of
   `bInterfaceClass = 8`, `bInterfaceSubClass = 6`, `bInterfaceProtocol = 80`
   (0x50, Bulk-Only Transport). Enumeration and configuration are identical;
   the difference is entirely in what matches afterwards.

2. `ioreg -r -n "Virtual USB Mass Storage Device"` — 12.7.6 shows the whole
   stack down to an `IOMedia` named for the volume. 12.0.1 stops at
   `IOUSBHostInterface` with no child.

3. On 12.0.1, `IOUSBMassStorageDriver.kext` is present in
   `/System/Library/Extensions`, and its `Info.plist` carries the personality
   that would match: `IOUSBMassStorageInterfaceNubSCSI`, keyed
   `bInterfaceClass = 8` / `bInterfaceSubClass = 6` on provider class
   `IOUSBHostInterface` — an exact match for the descriptors in probe 1.

4. `kmutil inspect` — the 12.0.1 boot kernel collection does not list the
   kext. 12.7.6's lists `IOUSBMassStorageDriver 210.120.3` and
   `AppleUSBMassStorageInterfaceNub 533.120.2`.

5. The guest's own `kernelmanagerd` log across an attach records no load
   request for the kext — only unrelated `com.apple.fileutil` and
   `com.apple.filesystems.autofs` loads — confirming nothing even tries.

6. The same image attached as a `VZVirtioBlockDeviceConfiguration` mounts on
   12.0.1, and the guest agent was installed from it that way. The image is a
   raw GPT disk holding one APFS container, so the guest reads it with no USB
   stack involved.
