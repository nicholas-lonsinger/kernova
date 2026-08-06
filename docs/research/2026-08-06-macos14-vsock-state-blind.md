# macOS 14 is state-blind on a non-blocking vsock connect, like 13

**Date:** 2026-08-06 · **Host:** M1 Max, 32 GB, macOS 27.0 · **Guest:** macOS 14.8.8, Kernova library VM, 4 vCPU / 8 GB

## Summary

macOS 14 exhibits the identical non-blocking vsock connect defect documented
for 13 in `2026-08-06-macos13-vsock-nonblocking-state-blind.md`: the
transport establishes (the host accepts and holds every attempt) while the
guest fd stays state-blind — `setsockopt` rejects `SO_RCVTIMEO` and
`SO_SNDTIMEO` with `EINVAL`, and the first `Hello` send dies against a
channel whose kqueue reader has already seen phantom EOF or whose write
fails outright. With 13 and 14 both affected and macOS 26/27 the oldest
releases where the non-blocking idiom is production-proven, the guest
client's OS split sits at 26: blocking `connect(2)` below, non-blocking
poll at 26 and above.

## Method

The 0.54.0 agent (build with POLLHUP deferred to `SO_ERROR`, so the connect
guard itself passes) in a clean 14.8.8 guest:

1. Host: 71 `Accepted vsock connection` lines, all on the control port,
   over ~360 s at a 5.0–5.5 s cadence; the log and clipboard ports were
   never reached. No `Guest agent connected` line for the VM, ever.
2. Guest (`log stream --level debug`, subsystem `app.kernova.macosagent`),
   every cycle: `setsockopt SO_RCVTIMEO failed: errno=22`, the same for
   `SO_SNDTIMEO`, then `Connected 'control' to host vsock port 49154`, then
   `Failed to send control Hello` — `VsockChannelError` case 1 (`.write`)
   in ~2 of 3 cycles, case 0 (`.closed`, the reader's phantom EOF winning
   the race) in the rest.
3. The `revents=16` connect-guard variant seen on 13's first run did not
   appear — this build's guard defers POLLHUP, isolating the remaining
   failure to the socket's unusable post-connect state, not the guard.
