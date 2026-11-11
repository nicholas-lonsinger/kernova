# A New Machine clone of a set-up macOS guest boots to the desktop

**Date:** 2026-11-11 · **Host:** macOS 27.2.1, Kernova Debug build of
`02eb1f0a` · **Guest:** macOS 27.2.0, automatic login on, Setup Assistant
long finished

## Finding

A macOS guest cloned as a New Machine boots with a machine identity of its
own and goes straight to the desktop, logged in automatically. A new machine
identifier did not bring up Setup Assistant or a login window.

| VM | MAC address | `IOPlatformUUID` | Serial | First stable screen |
|---|---|---|---|---|
| Source | `2e:43:28:63:bc:2d` | `C0932F09-AAF3-5506-BD91-A0572554E24A` | `ZT3JP423JP` | — |
| New Machine clone | `32:05:e8:89:6a:fb` | `1CE6EA34-D9F3-56EF-8B23-DD7AA22EF694` | `Z4DD5CH7GJ` | Desktop, 36 s after start |
| Exact Copy | same as source | same as source | same as source | Desktop, 19 s after start |

All three report `VirtualMac2,1` and the same console user.

## Method

`kernova clone <id> --id --new-machine` and `--exact-copy` on a stopped
source, one VM running at a time. Each clone was started and watched until
two frames 30 s apart matched, then read over SSH:
`ioreg -rd1 -c IOPlatformExpertDevice` for the UUID and serial, and
`stat -f%Su /dev/console` for the console user. On an earlier run the same
day, a New Machine clone of this guest also had `/etc/kcpassword`,
`autoLoginUser` and `/var/db/.AppleSetupDone` in place.

## Not covered

One guest version, with automatic login on and no Apple Account signed in.
A guest signed in to an Apple Account, or one cloned before its first setup
finished, was not tried.
