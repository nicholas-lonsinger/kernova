# VZ display dimensions: constructors accept anything, validate() caps at 16384 per axis

**Date:** 2026-08-01 · **Host:** M1 Max, 32 GB, macOS 27.0, Xcode 27.0 SDK

## Summary

Both VZ display types — `VZMacGraphicsDisplayConfiguration` and
`VZVirtioGraphicsScanoutConfiguration` — enforce a **16384-pixel per-axis
ceiling**, and enforce it only in `VZVirtualMachineConfiguration.validate()`:

- The initializers never throw. Both constructed at every probed size up to
  1,048,576 px per axis, and `pixelsPerInch` from 1 to 1,048,576. The
  exception-at-construction failure mode hypothesized in issue #691 does not
  exist.
- `validate()` accepts up to exactly 16384 on each axis independently —
  16384×16384 passes for both types, so the limit is per-axis, not area — and
  rejects 16385 with a catchable `VZErrorDomain` error: "The display
  dimensions are larger than the maximum supported display dimensions" (mac)
  / "The scanout dimensions are larger than the maximum supported scanout
  dimensions" (virtio).
- 1×1 validates for both types; VZ imposes no floor above zero.
- A diskless EFI VM with a 16384×16384 virtio scanout starts successfully,
  so validate's ceiling is the real gate, not an optimistic one.

Consequences for Kernova: `DisplayBootSizing.maximumDimension` (8192) sits at
half the framework ceiling, so no UI-admitted value can be rejected; and a
hand-edited `config.json` beyond 16384 fails at `ConfigurationBuilder`'s
existing `try vzConfig.validate()` as an ordinary catchable error — a start
failure, not a crash. 16384 equals the Apple-GPU maximum texture dimension,
suggesting the ceiling is hardware-derived and could differ on other chips —
one more reason to keep Kernova's own cap below it rather than chase it.

## Method

A standalone Objective-C probe (ObjC so `@try/@catch` can intercept the
hypothesized `NSException`), compiled with `clang -fobjc-arc -framework
Virtualization` and ad-hoc signed with `com.apple.security.virtualization`:

1. **Construction:** binary search per axis over [800, 2²⁰] (and
   `pixelsPerInch` over [1, 2²⁰]), catching `NSException`. No throw at any
   probed value for either type.
2. **Validation:** binary search with `validateWithError:` as the predicate
   over full configurations — virtio scanout inside an EFI/`VZGenericPlatform`
   config, mac display inside a `VZMacPlatformConfiguration` built from
   `VZMacOSRestoreImage.fetchLatestSupported`'s hardware model with fresh
   auxiliary storage and machine identifier. Both converge on 16384 per axis;
   width and height searched independently, then the combined maximum and 1×1
   checked directly.
3. **Start:** the EFI config from step 2 at 16384×16384, `VZVirtualMachine`
   on a private serial queue, `startWithCompletionHandler:` — completes
   without error (firmware idles with no disk; stopped immediately after).
