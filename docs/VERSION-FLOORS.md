# Version floors

Read this when choosing how to deliver something to a guest, or when a feature works on one guest and not another. Its reader is deciding an approach, not writing an `@available` — the compiler owns those, and Kernova's deployment target is in the project file.

Two different questions live here and are easy to conflate. **Guest-side** floors are what the guest's own kernel and userspace can do; the host API exists at every one of them, so a call that succeeds on the host tells you nothing. **Host-side** limits are what Virtualization.framework offers this build of Kernova at all.

## Guest-side floors — macOS guests

| Capability | Floor | Evidence |
|---|---|---|
| A USB mass storage device binds a driver and mounts | macOS **12.3** | [2026-08-07 note](research/2026-08-07-macos12-usb-mass-storage.md) — below it the device enumerates and nothing claims it, because `IOUSBMassStorageDriver.kext` is not in the guest's boot kernel collection |
| A virtio block device mounts | none within what Virtualization can install | Same note, probe 6 — a raw GPT/APFS image mounts on 12.0.1 |
| Guest-initiated virtio-vsock connects to a host listener | none within what Virtualization can install | [2026-07-31 note](research/2026-07-31-macos12-guest-vsock.md) — 12.0.1 and 12.7.6 both complete the handshake |
| `VZMacTrackpadConfiguration` is used instead of the USB pointing device | macOS **13.0** | `VZMacTrackpadConfiguration.h` discussion; pairing both devices is what makes an older guest work, and `ConfigurationBuilder.configureMacOSDevices` does exactly that |
| SPICE clipboard | never, at any version | macOS ships no `spice-vdagent` counterpart; macOS guests reach the clipboard over vsock instead (`ConfigurationBuilder.configureClipboardSharing`) |

A guest's version is not a thing Kernova can look up on demand — see `GuestAgentDiskDelivery.effectiveGuestVersion`, which reads the agent's last report and falls back to the image the VM was installed from.

## Host-side limits

**A running VM's device set is fixed at boot, except over USB.** `VZUSBController.attach(device:)` / `detach(device:)` are the only APIs that add or remove a device from a live VM. A live `VZVirtioFileSystemDevice` can be pointed at a different share, but that changes a device rather than adding one.

Anything else — a storage device, a network device, a socket device — costs a restart. That is why a guest taking the agent disk over virtio carries it at every boot rather than on demand.

**`VZUSBPassthroughDeviceConfiguration` is macOS 27.0**, above Kernova's deployment target, so it needs an availability guard. Every other Virtualization API Kernova uses is available unconditionally.
