# Releasing a VZVirtualMachine on the main thread costs under 0.2 ms

**Date:** 2026-08-18 · **Host:** M1 Max, 32 GB, macOS 27.0, Xcode 27.0 SDK, Debug build against deployment target 26.0 · **Guest:** macOS 26.6.2, 8 GB RAM, 4 cores, inline display

## Summary

Every stop releases the `VZVirtualMachine` on the main thread. Measured across
both stop paths, the whole teardown — the session actor's release, the display
view's detach, and the deallocation that frees the VM — totals **0.11–0.19 ms**,
about 1% of a 16.7 ms frame. Nothing about it is perceptible.

The deallocation that actually frees the VM cost 79 µs and 95 µs. An 8 GB guest
memory mapping does not make it slower, which says VZ's real teardown is not
synchronous in `dealloc`.

## Measurements

Two runs, one per stop path. `detach` is `VZVirtualMachineView.virtualMachine =
nil` in isolation; `vmRelease` is the release that follows it, measured
separately by holding the VM alive across the detach.

| Path | `session = nil` | view `detach` | `vmRelease` | Total |
|---|---|---|---|---|
| Guest shutdown (`guestDidStop`) | 69 µs | 23 µs | 95 µs | 187 µs |
| Force Stop | 12 µs | 21 µs | 79 µs | 112 µs |

## Who drops the last reference

`VMInstance.tearDownSession()` clearing `session` is never the release that
frees the VM while a display is showing. `VZVirtualMachineView.virtualMachine`
still holds it, and `ObservationLoop` re-applies through `Task { @MainActor }`,
so the view gives the VM up a turn or more later — after `tearDownSession()`
has returned. On the `guestDidStop` path that is guaranteed: the event arrives
with `status` still `.running`, and `resetToStopped()` runs in a single
main-actor turn, so the view is always still attached when `session` is cleared.

The session actor's own release was not always the same event either: on the
Force Stop run something else held the last reference and dropped it 153 µs
later, still on main.

## Method

Three temporary instrumentation points, reverted after the run: a `deinit` on
`VMSession` logging the releasing thread, a `ContinuousClock` around
`session = nil` in `tearDownSession()`, and a split timer in
`VMDisplayBackingView.show()` that holds the VM in a local across the detach so
the view's own work and the deallocation are timed apart. All at `.notice`, read
back with `log show`.

## Bearing on isolated deinit

`isolated deinit` on an actor whose executor is a `DispatchSerialQueue` does
move both the deinit body and the release of stored properties onto that queue —
confirmed in a standalone program under `-swift-version 6`. It alone would not
move this work off main, because the display view, not the session, drops the
last reference. Getting the VM's deallocation onto the queue needs the display
holders to detach first, which is structure worth roughly 0.15 ms per stop.
