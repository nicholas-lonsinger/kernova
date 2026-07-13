# Raw vsock transport throughput under Virtualization.framework

**Date:** 2026-07-13 · **Hardware:** M1 Max, 32 GB, macOS 26 host · **Guest:** macOS 26, 4 vCPU / 12 GB, throwaway VM · **Tracking issue:** #377

## Summary

The raw memory-to-memory vsock transport between a macOS guest and the host
was measured directly for the first time (no public benchmark of VZ vsock
existed as of 2026-07). The transport is **not** packet- or syscall-bound: it
is gated by the **writer-side `SO_SNDBUF`** of the AF_UNIX socketpair backing
each `VZVirtioSocketConnection`, which is born at XNU's system default of
**8 KiB** (`net.local.stream.sendspace`).

| Config (single stream) | guest→host | host→guest |
|---|---|---|
| Raw vsock, stock | ~750 MiB/s | ~715 MiB/s |
| + `setsockopt(SO_SNDBUF, ≥256 KiB)` on the VZ fd — **app-shippable** | — | **~6,400 MiB/s (54 Gbps)** |
| + host sysctl `net.local.stream.sendspace=1m` — root, **not shippable** | **~4,900 MiB/s (41 Gbps)** | ~6,400 MiB/s |
| Kernova clipboard stack at the time (post-#544, per #377) | 371–415 MiB/s | ~366 MiB/s |

Consequences for Kernova:

1. **Shippable:** setting `SO_SNDBUF` (knee at 256 KiB; 1 MiB is safe) on the
   fds `VsockListenerHost` accepts raises the host→guest *transport* ceiling
   ~9×. 64 KiB frame writes are optimal in the unlocked regime — no chunk or
   window change is needed or wanted.
2. **guest→host transport is capped at ~750 MiB/s for a shipping app.** The
   writer is a socket inside Apple's `com.apple.Virtualization.VirtualMachine`
   helper process, unreachable per-fd from the host app. Feedback-to-Apple
   material. The app's guest→host stack (~415 MiB/s) still has ~1.8×
   app-stack headroom below that cap — the #377 per-chunk work remains the
   lever there.
3. **Anti-levers (measured, do not pursue):** parallel streams (sublinear
   stock — 1.37×@2, 1.9×@8 — and *counterproductive* after the unlock);
   chunk-size increases (64 KiB→4 MiB is flat); guest-side `SO_SNDBUF`/
   `SO_RCVBUF` (ignored); guest `net.vsock.sendspace/recvspace` sysctls
   (writable at runtime but no effect at 2–8 MiB).

## Method

Out-of-tree lab (scratch code, deliberately not committed): a ~250-line raw
`AF_VSOCK` C daemon in the guest and a ~600-line standalone Swift CLI host —
no framing, protobuf, acks, hashing, or disk on either side, so the number is
transport + syscall only. Key design facts, all verified empirically:

- **macOS guests support guest-initiated vsock connections only**
  (`vsock(4)`), matching the app's host-listens topology. The guest daemon
  keeps a pool of 16 idle outbound connections to a `VZVirtioSocketListener`;
  the host pops accepted fds per run. Each connection serves one request:
  a 48-byte header (direction, sizes, buffer options) → payload → 24-byte
  timing reply from the guest, so both ends' timings are captured and a run
  only completes when the receiver has drained every byte (no buffered-but-
  undelivered illusions).
- An **ad-hoc-signed CLI with `com.apple.security.virtualization`** boots a
  Kernova VM bundle headless: `config.json`'s base64 `hardwareModelData`/
  `machineIdentifierData` → `VZMacPlatformConfiguration` +
  `AuxiliaryStorage` + `Disk.asif` via `VZDiskImageStorageDeviceAttachment`
  + `VZMacOSBootLoader`; the guest daemon is a root LaunchDaemon so headless
  boots need zero interaction.
- Methodology per #377's rules: standalone launches only (no Xcode
  instrumentation), quiet host, repeated runs (spread was ~±3% except where
  noted), Kernova quit during measurement.
- Payloads 4–12 GB per run, pseudo-random fill, per-syscall chunk sizes and
  socket buffers set per-spec from the host.

## Attribution chain (how the gate was isolated)

1. **Stock ceiling ~750 MiB/s both directions, flat across 64 KiB–4 MiB
   chunks** — not syscall-bound. Probing the accepted fd: a plain AF_UNIX
   socket, `SO_SNDBUF=8192 SO_RCVBUF=8192` (= `net.local.stream.*` defaults).
2. **`SO_SNDBUF=1 MiB` on the host fd → host→guest 715 → 6,320 MiB/s
   (8.8×).** CPU per 4 GB fell 2.0 s → 0.25 s sys: the 8 KiB send buffer had
   forced per-8-KiB writer↔VMM ping-pong. Knee measured at 256 KiB; the
   unlock fully survives 64 KiB writes (fastest run: 6,449 MiB/s).
3. **guest→host resisted every app-side knob** (host `SO_RCVBUF`, guest
   setsockopt, guest vsock sysctls at 2 MiB/8 MiB): still ~750. So the g2h
   gate is on the VMM→host leg, i.e. the *writer's* buffer on the other end
   of the socketpair.
4. **In-process fd sweep** (bump `SO_SNDBUF` on every AF_UNIX fd in the
   benchmark process): only ~15 such fds exist and g2h didn't move — the
   virtio device backends run in the `com.apple.Virtualization.VirtualMachine`
   helper process, so the peer socket isn't in the host app's fd table.
5. **System-default proof:** raising `net.local.stream.sendspace` to 1 MiB
   (root; informational only; reverted and read back to 8192 afterwards) so
   the helper's sockets are *born* with a large send buffer unlocked
   guest→host to 3.5–4.9 GiB/s — and host→guest reached ~6.3 GiB/s with no
   setsockopt at all. Attribution complete: writer-side send buffer is the
   entire story, in both directions.

Post-unlock details: g2h peaked at 4,907 MiB/s with `SO_RCVBUF=1 MiB` added
(~+15%); 64 KiB chunks slightly beat 1 MiB chunks; 2 parallel streams were
slower than 1 in both directions.

## Reference points

- Raw AF_UNIX socketpair on the same host, default buffers: ~2.3 GiB/s
  (tuned, per the #377 review: 22.7 GiB/s) — the no-VM syscall ceiling.
- App stack over AF_UNIX loopback: ~710–1,170 MiB/s (#377).
- VZ virtio-net sibling transport: ~25 Gbps (external report).
- Linux vhost-vsock (in-kernel, not comparable to VZ's userspace path):
  25–40 Gbps; Firecracker's userspace-proxied vsock (closest architectural
  analog): ~10 Gbps.

## Reproduction

The lab (guest daemon `vsockblast.c`, host CLI `vsockbench`, Makefile,
runbook, full RESULT logs) lived in `Scratch/vsock-lab/` — locally
git-excluded by design; this document is the durable record. Rebuilding it
from this report is a few hours' work; the load-bearing facts are all in
[Method](#method) above. Raw per-run RESULT lines for every batch are
preserved in the #377 comment of 2026-07-13.
