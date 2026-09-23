# A member interface of the app's own holds a vmnet network's run

**Date:** 2026-09-20 · **Host:** M1 Max, 32 GB, macOS 27.0 (26A428) ·
**Binary:** a development build signed with `com.apple.vm.networking`,
sandboxed · **Guest:** Ubuntu Desktop 26.04, Shared Network, DHCP reservation
`192.168.64.8`

## Summary

`vmnet_interface_start_with_network` succeeds from the sandboxed entitled app,
and the interface it returns counts as an internal interface of the network:
it holds the network's run — and with it the `/etc/bootptab` entries that serve
the DHCP reservations — for as long as it is up, whatever the guests on that
network do. A sole guest's in-guest reboot, which ends the run when the guest's
interface is the only one
(docs/research/2026-09-18-vmnet-dhcp-reservations-lapse-on-network-stop.md),
leaves the run untouched while such a member is held, and the guest returns to
its reserved address.

## The member, observed

Six starts, all from the entitled build: `VMNET_SUCCESS` (1000) on every one.
InternetSharing checks the caller's code signature, and the entitlement carries
that check.

The first member arriving on a network logs a start, the same sequence a first
guest does, and writes `/etc/bootptab`:

```
netrbCreateInterface
mis_network_add_internal_interface
mis_network_start
```

A guest joining afterwards logs `netrbCreateInterface: adding interface to
existing network`, and `/etc/bootptab` is left as it is.

With the member held, two in-guest reboots (GNOME → Restart) logged only:

```
netrbRemoveInterface: from vms
```

— no `mis_network_cleanup_bridge`, no `mis_network_stop`. `/etc/bootptab` was
byte-identical before and after each reboot, the guest's DHCP ACK carried
`192.168.64.8` again, and `kernova ip` agreed with `arp -an`.

On the bridge the member is distinguishable from a guest:

```
member: vmenetN flags=3<LEARNING,DISCOVER>
```

A guest's interface carries the `VIRTIO` flag; the member does not.

## What the member does, and does not, put on the wire

Nothing is originated from it. Kernova calls neither `vmnet_read` nor
`vmnet_write` on the interface, so no frame is ever sourced from it: no DHCP
lease of its own, no ARP entry, no entry in the bridge's address cache. The
MAC address is not what keeps it inert — `vmnet_allocate_mac_address_key:
false` is accepted at this entry point and changes nothing, and a MAC is
assigned either way.

## Timing and lifetime

- The start does not block: it returns an `interface_ref` in 0.03–0.08 ms, and
  its completion handler runs 19–163 ms later on the supplied queue. The
  interface is up at the completion.
- The start retains the network object, and `vmnet_stop_interface` releases it
  — from the stop's completion handler, about 90 ms after the stop is issued.
  A `vmnet_network_create` pinned to the same subnet before that release lands
  fails, which is the conflict a still-held network produces.

## Virtualization.framework says nothing about a guest reboot

`VZVirtualMachineNetworkDeviceAttachment`'s disconnect delegate does not fire
for an in-guest reboot. `NetworkAttachmentCoordinator.attachmentWasDisconnected(error:)`
logs a `.warning` as its first statement, ahead of every guard, and that record
is absent from a live `/usr/bin/log stream --level debug` and from the
persisted store across both reboots. VZ removes the guest's vmnet interface and
adds it back — 3 s apart, with the guest re-issuing DHCP about 8 s in — without
telling the app.

## Method

1. A development build starting a member interface on each app-managed network
   at the first attachment it handed out, and stopping it once no VM held one.
2. InternetSharing's lines captured with `/usr/bin/log stream --level debug`
   (`subsystem` unfiltered; the daemon's records are debug-only and reach no
   persisted store), timed against Kernova's own records.
3. `/etc/bootptab` compared by `shasum` and `stat -f '%Sm %z'` before and after
   each reboot; `arp -an` and `/var/db/dhcpd_leases` for the address the guest
   actually took, `kernova ip` for what the app reported.
4. `ifconfig bridge100` for the member and guest flags.
5. The start and stop timings from `#log` records emitted at the call and in
   the completion handler.
