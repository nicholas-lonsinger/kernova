# macOS 12 vsock never completes a non-blocking connect

**Date:** 2026-08-02 · **Host:** M1 Max, 32 GB, macOS 27.0 · **Guest:** macOS 12.7.6, Kernova library VM, 4 vCPU / 8 GB

## Summary

On a Monterey guest, `connect(2)` on an `O_NONBLOCK` `AF_VSOCK` socket
returns `EINPROGRESS` and then never completes: `poll(POLLOUT)` returns
immediately with `revents = POLLHUP` (0x10) and `SO_ERROR == 0`,
`getpeername(2)` keeps reporting `ENOTCONN` through an entire 3 s deadline, a
probing re-`connect(2)` is rejected with `EINVAL` (not the classic BSD
`EALREADY`/`EISCONN`), and the host's `VZVirtioSocketListener` sees the
connection arrive only at the moment the guest closes the fd — the queued
request surfaces during socket teardown, so a host-side accept is evidence of
the guest *giving up*, not of establishment. The same `connect(2)` issued on
a blocking socket completes immediately (the 2026-07-31 note's end-to-end
probe). macOS 13+ guests complete the identical non-blocking sequence with a
normal `POLLOUT`. Non-blocking connect is therefore unusable on Monterey
vsock; a blocking connect is safe there because the transport is local-only —
the hypervisor answers accept or refusal promptly, with no remote peer to
wait out.

## Method

The guest agent's own connect path (`VsockGuestClient.openVsockToHost`)
against Kernova's always-installed control listener on port 49154, observed
from both ends of the same instants across three agent builds:

1. Poll-verdict build (`revents` treated as failure): guest logs `connect()
   to 'control' port 49154 failed: revents=16` within ~10 ms of the attempt,
   every 5 s retry; that log line renders the `revents` fallback only when
   `getsockopt(SO_ERROR)` returned 0. Host log shows an `Accepted vsock
   connection` / channel-EOF pair ms apart at the same cadence.
2. `connect(2)`-probe build: `failed: errno=22` (EINVAL) on the same instant
   cadence.
3. `getpeername(2)`-probe build: the retry cadence stretches from ~5 s to
   ~8 s — the 5 s retry sleep plus the full 3 s deadline spent in
   `ENOTCONN` — and the host's accept timestamp still lands ms before the
   guest's close, pinning the accept to teardown rather than establishment.
4. The 2026-07-31 note's Ruby probe (blocking `Socket#connect`) completes on
   the same guest, isolating the failure to the non-blocking path.
