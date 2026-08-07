# A macOS 13 non-blocking vsock connect leaves the socket state-blind

**Date:** 2026-08-06 · **Host:** M1 Max, 32 GB, macOS 27.0 · **Guest:** macOS 13.7.8, Kernova library VM, 4 vCPU / 8 GB

## Summary

On macOS 13, a non-blocking `AF_VSOCK` connect establishes at the transport
level — the host's listener accepts and holds the connection — but the guest
socket never reads as connected through any kernel readiness API:

- `poll()` returns `POLLHUP` alone (`revents=16`, no `POLLOUT`), with
  `SO_ERROR` reading 0.
- `kqueue`-based readers (`FileHandle.readabilityHandler`) fire immediately
  with zero bytes available — phantom EOF on a live connection.
- `setsockopt` rejects `SO_RCVTIMEO` and `SO_SNDTIMEO` with `EINVAL`.

Interpreting any one signal charitably just moves the failure to the next:
treating `POLLHUP`-with-`SO_ERROR`-0 as completion (correct POSIX reading)
gets past the connect, and the phantom EOF then tears the channel down
before the first frame is sent. The non-blocking idiom is unusable as a
whole on this OS; no readiness API on the fd tells the truth.

A blocking `connect(2)` is the usable path: macOS 12 — the same driver
family, whose non-blocking connect never completes at all
(`2026-08-02-macos12-vsock-nonblocking-connect.md`) — runs the identical
channel stack (kqueue reader, socket timeouts) over a blocking connect with
every API behaving. Released agents on macOS 26/27 run the non-blocking
idiom cleanly, so the readiness plumbing works there; where between 13 and
26 it starts working is untested.

## Method

The 0.54.0 agent in a clean 13.7.8 guest, two builds observed end to end:

1. Build with `POLLHUP` treated as fatal: guest logs `connect() to
   'control' port 49154 failed: revents=16` every ~5.3 s, paired 1:1 with 61
   host-side `Accepted vsock connection` lines over 5.5 min. `revents=` in
   the message (not `errno=`) proves the guard's `SO_ERROR` read returned 0.
2. Build deferring `POLLHUP` to `SO_ERROR`: the connect proceeds — per
   cycle the guest now logs both `SO_RCVTIMEO`/`SO_SNDTIMEO` failures with
   `errno=22`, then `Connected 'control' to host vsock port 49154`, then
   `Failed to send control Hello` with `VsockChannelError` case 0
   (`.closed`): the kqueue reader saw EOF and tore the channel down between
   construction and the send, ~1 ms. 138 identical cycles.
3. The identical binary on a 12.7.6 guest (blocking-connect path) held a
   session through install, clipboard both directions, and a 95 s
   save/restore the same day — no timeout-option failures, a working kqueue
   reader — isolating every symptom to the 13 non-blocking connect, not the
   channel stack.
