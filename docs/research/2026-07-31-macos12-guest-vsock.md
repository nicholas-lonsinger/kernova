# macOS 12 guests have working guest-side virtio-vsock

**Date:** 2026-07-31 · **Host:** M1 Max, 32 GB, macOS 27.0 · **Guests:** macOS 12.0.1 and 12.7.6, Kernova library VMs, 4 vCPU / 8 GB

## Summary

Both endpoints of the Monterey range — 12.0.1, the oldest guest
Virtualization.framework can install, and 12.7.6, the last release — ship the
`AppleVirtIOSocket` transport driver and complete guest-initiated `AF_VSOCK`
connections to a host `VZVirtioSocketListener` end-to-end. A guest-agent
deployment floor of macOS 12.0 therefore has no transport-layer obstacle.

This corrects the public record. The only direct claim on the web — repeated
by every secondary source — is one unsourced sentence in
[mdlayher/vsock PR #60](https://github.com/mdlayher/vsock/pull/60) ("Since
MacOS 13, it is able to virtualize MacOS with vsock support in the guest"),
and the circumstantial evidence (Monterey guests lack virtiofs, the multiport
console, and the SPICE agent; every shipping vsock guest agent, including
Tart's, supports 13+ only) points the same wrong way. Nobody had tested 12.

## Method

Each guest was created in Kernova from its catalog restore image, booted, and
probed from its own Terminal; the host side was Kernova's always-installed
control listener (port 49154), so the connect test exercises the exact
listener topology the guest agent uses. Three probes per guest, all passing
identically on 12.0.1 and 12.7.6:

1. `sysctl kern.osproductversion` — confirms the guest under test.
2. `ioreg -rc AppleVirtIOSocket` — prints the transport's IOKit node
   (`registered, matched, active`). XNU's `vsock_attach`
   (`bsd/kern/vsock_domain.c`) returns ENODEV from `socket(2)` when no
   transport has registered, so this node is the gate; its class name comes
   from the `AppleVirtIO.kext` symbol dumps.
3. End-to-end, entirely with the guest's stock `/usr/bin/ruby`:

   ```ruby
   ruby -e 'require "socket";s=Socket.new(40,1,0);puts "ok1";
            s.connect([12,40,0,49154,2].pack("CCvVV"));puts "ok2"'
   ```

   `40` is Darwin's `AF_VSOCK`; the packed 12 bytes are `sockaddr_vm`
   (`svm_len=12`, `svm_family=40`, `svm_reserved1: u16`, `svm_port: u32`,
   `svm_cid: u32`, native little-endian), targeting `VMADDR_CID_HOST` (2).
   `ok1` proves socket creation (no ENODEV — transport registered); `ok2`
   proves the connect handshake completed against the host listener.

Guest-initiated is the only direction macOS guests support (`vsock(4)`,
re-confirmed in the 2026-07-13 throughput note), which is the direction the
agent uses.
