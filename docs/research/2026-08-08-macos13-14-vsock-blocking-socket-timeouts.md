# macOS 13 and 14 accept the vsock socket timeouts on the blocking connect path

**Date:** 2026-08-08 · **Host:** M1 Max, 32 GB, macOS 27.0 · **Guests:** macOS
13.7.8 and 14.8.9, clean Kernova library VMs, 4 vCPU / 8 GB

## Summary

`setsockopt(SO_RCVTIMEO)` and `setsockopt(SO_SNDTIMEO)` both succeed on an
`AF_VSOCK` fd that reached the connected state through a blocking `connect(2)`
— the path `VsockGuestClient.openVsockToHost` takes below macOS 26. The
`EINVAL` these options return on 13 and 14 in
`2026-08-06-macos13-vsock-nonblocking-state-blind.md` and
`2026-08-06-macos14-vsock-state-blind.md` is a property of the non-blocking
connect idiom, one more face of the state-blind fd those OSes hand back
alongside `POLLHUP`-with-`SO_ERROR`-0 and the kqueue reader's phantom EOF.

So `VsockChannel.writeFramed`'s blocking `FileHandle.write` carries the
`socketTimeoutSeconds` bound on every macOS guest Kernova supports, on all
three channels.

Both guests also hold a full agent session over that path — control, log, and
clipboard connected, clipboard streaming in both directions.

## Method

The 0.57.0 agent installed into each clean guest from the mounted installer
disk, both VMs running concurrently for 15+ min:

1. In each guest, after all three channels had connected,
   `log show --last <n>m | grep -ci setsockopt` printed `0`.
   `applySocketTimeouts` logs a warning per rejected option on every connect,
   so zero is six consecutive acceptances per guest.
2. Host: six `Accepted vsock connection` lines total — one per channel per VM,
   no retries — and one `Guest agent connected` line each. 270 heartbeats from
   13.7.8 and 183 from 14.8.9, on control sessions that never reconnected.
3. Clipboard both ways on both guests: `Paste from Mac` streamed a 27-byte
   snapshot host→guest, and ⌘C in the guest streamed three representations
   (659 bytes on 13.7.8, 667 on 14.8.9) guest→host, each on the first attempt.
