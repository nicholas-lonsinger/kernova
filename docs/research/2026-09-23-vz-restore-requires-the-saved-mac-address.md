# A VZ restore fails when only the network device's MAC address differs

**Date:** 2026-09-23 · **Host:** macOS 27.0 (26A428), Kernova Debug build 901
(`b73d4f3e`) · **Guest:** macOS 27.0 (26A428), `shared` network on an
entitled build · **Tracking issue:** #1318

Supersedes the MAC address section of
[2026-09-22-vmnet-network-run-and-forwarding-rules.md](2026-09-22-vmnet-network-run-and-forwarding-rules.md),
which rested on commit `6c0b3bfc` — a fix that changed the MAC address and the
machine identifier together — and on Apple's sample app, which pins a MAC
address without stating why.

## Summary

With the save file, machine identifier, hardware model, auxiliary storage,
disks and every other configuration field unchanged, a different
`VZVirtioNetworkDeviceConfiguration.macAddress` makes `restoreMachineStateFrom`
fail, 2 of 2 runs:

```
The virtual machine failed to restore with error “invalid argument”. [VZErrorDomain 12; underlying: none]
```

The VM helper logs `[com.apple.virtualization:breadcrumb] 0xf8a9a831000000b9`
about 60 ms before each failure, and never around a successful restore. Putting
the original MAC address back restores the same save file, 2 of 2 runs. No
`ctkd` or `SecKey` refusal (see
[2026-09-06-vz-restore-permission-denied-sep-refusal.md](2026-09-06-vz-restore-permission-denied-sep-refusal.md))
occurred in any run.

Apple's header states the rule without naming the field: a configuration "not
compatible with the content of the file" fails with `VZErrorRestore` and an
invalid-argument reason (`VZVirtualMachine.h`, `restoreMachineStateFromURL:`).
The same reason covers a file saved by newer software and a host changed by a
software update, so the error text alone does not identify the MAC address.

## Method

1. Clone an Ephemeral Mode macOS VM with `kernova clone --keep-identity`; the
   clone's MAC address is M1. Start it, let it take a DHCP lease, run
   `kernova suspend`, then `kernova quit`.
2. With no Kernova process running, change only `macAddress` in the clone's
   `config.json` to M2 (last octet flipped; still locally administered and
   unicast). `diff` against a backup shows that one line; a `jq -S
   'del(.macAddress)'` comparison shows every other field identical.
3. Relaunch and `kernova resume`. Read the restore records:

   ```
   /usr/bin/log show --last 5m --predicate 'subsystem BEGINSWITH "app.kernova" OR subsystem == "com.apple.virtualization"' --style compact
   ```

   and the Secure Enclave check from the 2026-09-06 note's method.
4. Control: quit, copy the backup back (`cmp` exits 0), relaunch, resume the
   same save file.
5. Re-save from the running clone and repeat steps 2–4.

The `shared` network is created fresh at every launch, so the attachment is
rebuilt the same way in failing and passing runs.

## Results

| Run | MAC | `kernova resume` | Save file after |
|---|---|---|---|
| 1 | M2 | exit 1, “invalid argument” | kept |
| 2 | M1 | exit 0, running, same DHCP address | consumed |
| 3 | M2 | exit 1, “invalid argument” | kept |
| 4 | M1 | exit 0, running | consumed |

## What this decides

A VM's MAC address is part of what its saved state restores into: any path
that writes a configuration beside a save file — a warm snapshot revert, an
edit, a clone that copies state — keeps the MAC address that state was saved
under, or does not keep the state.
