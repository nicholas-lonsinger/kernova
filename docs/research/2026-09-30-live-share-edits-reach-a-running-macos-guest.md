# A live share swap reaches a running macOS guest

**Date:** 2026-09-30 · **Host:** macOS 27.0, Kernova Debug build of the
throwaway spike `4e504fd5` · **Guests:** macOS 13.7.8 and macOS 27.0.0 ·
**Tracking issue:** #1431

## Summary

Setting `VZVirtioFileSystemDevice.share` on a running macOS guest's automount
device (`VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag`) to a
new `VZMultipleDirectoryShare` changes what the guest sees under
`/Volumes/My Shared Files` without a restart, on both guests measured.
`share` is a settable property of the running device in
`VZVirtioFileSystemDevice.h`.

- **Add** (one share → two): the guest listed both within 3 s on macOS 13 and
  about 1 s on macOS 27; the added folder's marker file read back, and a file
  the guest wrote there reached the host.
- **Remove** (two → one): the guest listed only the remaining share within 5 s
  on macOS 13 and about 1 s on macOS 27.
- **Suspend, then resume** after live edits: exit 0 and the same session on
  both guests; on macOS 27 every share read back after the resume. (macOS 13's
  multi-share resume defect is independent of the swap: #1440.)
- **Force stop, then cold start** after live edits (macOS 13): the guest
  showed exactly the list `config.json` held, which was the list last
  installed live.

Adding the first share or removing the last adds or removes the device
itself. The spike refused removing the last share on a running guest, and did
not attempt adding the first.

## Method

1. Keep-identity clones of the pool VMs (`kernova clone --keep-identity`), each
   booted with one share. The shares are folders under `~/Downloads/kv1431-a`,
   `-b`, `-c`, each holding a marker file naming it.
2. With the guest running, `kernova share add` and `kernova share remove`
   against the clone. The spike committed the new list to `config.json`, then
   set the device's share to a `VZMultipleDirectoryShare` built from that list
   as a boot builds it, holding each new folder's security scope as a boot does.
3. In the guest, `ls "/Volumes/My Shared Files"` and `cat` of each marker file
   after every edit; one file written from the guest into a live-added share.
4. Records from `/usr/bin/log stream` on the spike's own notice naming the
   shares each install carried.
5. `kernova suspend` and `kernova resume`, twice on macOS 13 and once on
   macOS 27, then the listing and marker reads again.
6. On macOS 13, `kernova stop --force --yes`, `kernova start`, and the listing
   again.

Not measured: macOS 14, 15 and 26 guests; a live swap on a paused guest; a
swap concurrent with a pause, save or snapshot capture.
