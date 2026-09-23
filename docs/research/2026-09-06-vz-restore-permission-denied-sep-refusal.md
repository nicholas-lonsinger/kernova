# A VZ restore's "permission denied" was the host Secure Enclave refusing the VM helper's key

**Date:** 2026-09-06 · **Host:** macOS 27.0, Kernova Debug build 777 · **Guest:**
macOS, restored cold from a termination save · **Tracking issue:** #1152

## Summary

`restoreMachineStateFrom` failed twice with `The virtual machine failed to
restore with error “permission denied”` (`VZErrorDomain` 12, no underlying
error). The text names no file and no sandbox check. At both failures the VM
helper's first Secure Enclave step was refused, with the same key id both times,
four minutes apart. The helper then exited 0 after about 100 ms. Its reason
reaches the unified log only through `ctkd` and the
`com.apple.security:seckey` category:

```
ctkd [com.apple.CryptoTokenKit:sepkey] <sepk:p256(u) kid=…>:
  (com.apple.Virtualization.VirtualMachine<pid>) unable to compute shared secret: error e00002e2(-536870174)
com.apple.Virtualization.VirtualMachine [com.apple.security:seckey]
  SecKeyCreateDecryptedDataWithParameters failed: NSOSStatusErrorDomain Code=-25308
```

`-25308` is `errSecInteractionNotAllowed`. Across two days of retained log those
records occur only at the two failures, never around a successful restore.

## Method

1. Read the records at each failure's `Restore failed for VM` timestamp:

   ```
   /usr/bin/log show --last 1h --predicate '(process == "ctkd" AND eventMessage CONTAINS "unable to compute shared secret") OR (subsystem == "com.apple.security" AND eventMessage CONTAINS "SecKeyCreateDecryptedDataWithParameters failed")' --style compact
   ```

2. Repeat the failing flow 12 times on the same commit: quit 3, 6, 22 and 45 s
   after a cold start; quit by `kernova quit` and by a quit Apple Event;
   relaunch hidden and with the display window open; resume 2–78 s after the
   app exited; a fresh app process for the start; and a restore of a save file
   the failing build had written.

## Results

12 of 12 restores succeeded, and so did a separate build's start → quit →
resume. The refusal is host-side and time-windowed, not a property of the save
file or of Kernova's save/restore path.

## What this decides

A restore that fails this way with those `ctkd` records present leaves the save
file sound, so `VirtualizationError.restoreFailed` keeping the saved state is the
right outcome.
