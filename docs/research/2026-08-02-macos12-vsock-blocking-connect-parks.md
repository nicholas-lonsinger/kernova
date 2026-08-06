# A macOS 12 vsock connect parks indefinitely when the host stops accepting

**Date:** 2026-08-02 · **Host:** M1 Max, 32 GB, macOS 27.0 · **Guest:** macOS 12.7.6, Kernova library VM, 4 vCPU / 8 GB

Supersedes the closing claim of
`2026-08-02-macos12-vsock-nonblocking-connect.md`, which held that a blocking
connect is safe on this transport because the hypervisor answers promptly.

## Summary

A blocking `connect(2)` on an `AF_VSOCK` socket stays in the kernel
indefinitely — observed parked for over 12 minutes — whenever the host side
holds a listener that never accepts. Darwin bounds `connect(2)` with no socket
option (`SO_SNDTIMEO` and `SO_RCVTIMEO` cover only `send`/`recv`), so a blocking
connect issued on the reconnect loop's own thread strands that loop for the life
of the process: the guest agent stays alive, logs nothing further, and never
reconnects, while its status reads disconnected. The host meanwhile sees
nothing at all — consistent with the queued request surfacing at the listener
only when the guest closes the fd, so a guest that never closes never appears.

Bounding it therefore takes a thread the caller can abandon, not a timeout
value. Abandoning the thread rather than closing its socket keeps descriptor
ownership unambiguous — closing an fd out from under an in-flight syscall is
undefined, and the fd number can be reused the moment `close` returns.

## Method

The guest agent's control, log, and clipboard clients against Kernova's
listeners, with the agent built from this branch's macOS 12 floor:

1. A mid-session clipboard-sharing enable (host policy `clipboard=false` →
   `true` on a running VM) resumes two paused reconnect loops at once. The
   control channel closed within ~5 s of that policy frame, at the same instant
   the guest's File Provider servicing connection came up.
2. `sample <agent pid> 2` then showed all 1491 samples of the reconnect thread
   in `__connect` (in `libsystem_kernel.dylib`), below
   `VsockGuestClient.openVsockToHost(port:label:clock:)` — parked, not spinning.
3. The park outlasted every recovery the guest offers: it held across ~12
   minutes, and `SIGKILL` on the agent was needed to clear it.
4. The host logged no `Accepted vsock connection` for the whole window while its
   own liveness timer kept ticking every 5 s, so the host was idle and willing —
   the connect never reached it.
5. After a guest restart the same build connected immediately and held 29
   consecutive 5 s heartbeats with the identical `clipboard=true` policy, which
   places the trigger in the mid-session enable rather than the policy value.
