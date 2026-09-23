# A vmnet network's run, its forwarding rules, and what a sandboxed app can see

**Date:** 2026-09-21/22 · **Host:** M1 Max, 32 GB, macOS 27.0 (26A428), Xcode
27.0 · **Binary:** development builds signed with `com.apple.vm.networking`,
sandboxed · **Guests:** macOS 27, macOS 12.7.6 and Ubuntu Desktop 26.04, on
Shared Network and Host Only

Apple Feedback, filed 2026-09-22 (Virtualization Framework):

- **FB24895271** — DHCP reservations and port-forwarding rules are discarded
  when the network's last interface is removed, despite the network object
  being retained.
- **FB24895264** — `vmnet_interface_{add,remove,get}_ip_port_forwarding_rule(s)`
  return `VMNET_FAILURE` synchronously on an interface attached to a
  `vmnet_network_ref`.
- **FB24895282** — suggestion: a `vmnet_network_ref` state-change callback and
  a DHCP lease query by MAC.

Apple DTS forum thread 822025 asked for the reservation report; r. 166418644
is the existing forwarding bug.

## A sole guest's in-guest reboot ends the network's run

An in-guest reboot of the only VM on a network makes Virtualization.framework
remove the VM's vmnet interface and add it back about one second later.
InternetSharing stops the network in between and starts it again with
neither its DHCP reservations nor its forwarding rules:

```
12:07:09.629 netrbRemoveInterface: from vms
12:07:09.700 mis_network_cleanup_bridge: no internal interface left, stopping network <private>
12:07:09.773 mis_network_stop: network <private> reset to idle        ← /etc/bootptab is now 0 bytes
12:07:10.883 netrbCreateInterface: adding interface to existing network <private>
12:07:10.986 mis_network_start: network <private> has been started    ← bootptab stays empty
12:07:17 – 12:07:27 bootpd: DHCP REQUEST ×3, then DISCOVER, REQUEST   ← guest lands on 192.168.65.16
```

The guest returns on a dynamic lease, and a forwarded host port refuses
connections — a refusal rather than a timeout, so the rule itself is gone,
not merely its target. Six of six reproductions: macOS 27 and Ubuntu 26.04
guests, Shared Network and Host Only, ephemeral and persistent VMs. With a
second VM attached, nothing is lost: the trigger is the interface count
reaching zero.

bootpd re-issues the same dynamic address to the same MAC (bootpd(8), and
observed), so the address moves once per network lifecycle, not on every
reboot.

`kernova restart`, pause/resume, and suspend/restore do not lose the
reservation.

Virtualization.framework reports none of this. `VZVirtualMachineDelegate.h`
documents `virtualMachine:networkDevice:attachmentWasDisconnectedWithError:`
as invoked when the network interface fails to start; across every reboot
above, the app's handler — which logs as its first statement — logged
nothing, since the re-add succeeds.

Holding an app-owned member interface on the network
(`vmnet_interface_start_with_network`) keeps the interface count above zero
and the run alive
(docs/research/2026-09-20-vmnet-member-interface-holds-a-network-run.md).
With the member held, every in-guest reboot below logged
`netrbRemoveInterface` and an interface re-added 1–2.5 s later, and no
`mis_network_stop`; `/etc/bootptab` kept its entries, bootpd ACKed the
reserved address, and a forwarded port reached an in-guest `nc -lk` before
and after:

| Guest | Network | Forwarding rule | Reserved address before → after |
|---|---|---|---|
| macOS 27, sole VM | Shared | 8022 → 8080 | 192.168.64.6 → 192.168.64.6 |
| macOS 27 and Ubuntu 26.04, rebooted 1 s apart | Shared | 8022 → 8080 | .64.6 / .64.8 → unchanged |
| macOS 27, sole VM | Host Only | — | 192.168.128.2 → 192.168.128.2 |
| Ubuntu 26.04, sole VM | Shared | 8023 → 8080 | 192.168.65.8 → 192.168.65.8 |
| Ubuntu 26.04, sole VM | Host Only | — | 192.168.128.2 → 192.168.128.2 |

In the two-guest run, only the member was on the network from 12:39:04.991
to 12:39:05.949. `ifconfig` showed the member
(`flags=3<LEARNING,DISCOVER>`) beside each guest's interface throughout.

## Forwarding rules can only be set at creation for a VZ guest

`vmnet_interface_add_ip_port_forwarding_rule`,
`vmnet_interface_remove_ip_port_forwarding_rule` and
`vmnet_interface_get_ip_port_forwarding_rules` return `VMNET_FAILURE` (1001)
synchronously on an interface started with
`vmnet_interface_start_with_network`, run no completion handler, and reach
no daemon (InternetSharing logs no `netrbAddPortForwardingRule`). The
descriptor — empty, or `vmnet_operation_mode_key = VMNET_SHARED_MODE` — made
no difference; three attempts across two builds, 45–150 s after the guest
booted.

In the same sandboxed process at the same moment, a standalone interface from
`vmnet_start_interface` accepts the same add: `VMNET_SUCCESS` at the call and
in the handler, the daemon logs
`port forwarding enabled on <if> proto tcp port 8044 to <private> port 8080`,
and `get` returns the rule. So neither the sandbox nor the entitlement is the
cause. A Virtualization.framework guest attaches only through
`VZVmnetNetworkDeviceAttachment(network:)`, so a running guest's rules cannot
change.

## A killed client's network keeps its subnet registered

Killing Kernova (`kill -9`) with a Shared Network VM up: InternetSharing
stops the dead client's networks at once but logs no `netrbRemoveNetwork`
for them, and the subnet stays taken. The relaunched app's create pinned
to the stored subnet was refused in both runs: with a VM started 3 s after
the kill, and 48 s after it. A fresh create does not free it: a pinned
create issued right after a fresh create and its release was refused
again. Both runs moved the network to a new subnet.

The 48 s run (the Kernova lines are the app's own records):

```
13:02:24.141 mis_client_release: stopping all networks of <private>
13:02:24.357 mis_network_stop: network <private> reset to idle
13:02:24.357 mis_network_stop: network <private> has been stopped
13:03:12.259 mis_network_validate_resource_availability: overlapping DHCP range between network <private> and network <private>
13:03:12.259 netrbCreateNetwork: unable to fulfill network
13:03:12.266 Kernova: Created shared network (fresh, 0 reservations, 0 forwarding rules): 192.168.65.1 mask 255.255.255.0
13:03:12.266 netrbRemoveNetwork: stopped idle network <private>      ← the fresh create, released
13:03:12.266 mis_network_validate_resource_availability: overlapping DHCP range between network <private> and network <private>
13:03:12.266 netrbCreateNetwork: unable to fulfill network             ← the stored subnet, again
13:03:12.279 Kernova: Created shared network (pinned, 8 reservations, 1 forwarding rules): 192.168.65.1 mask 255.255.255.0
```

The `netrbRemoveNetwork` that follows a fresh create is the release of that
create, not of the dead client's network.

## What a sandboxed process can read

- The host's IPv4 ARP table, through `sysctl` `NET_RT_FLAGS` /
  `RTF_LLINFO`, with each entry's expiry — on macOS 27 only with the
  `com.apple.developer.networking.topology-observation` entitlement; without
  it the table comes back empty (DTS,
  https://developer.apple.com/forums/thread/822025?page=2). A bridged
  guest's entry held for 30 minutes without being refreshed.
- Not `/var/db/dhcpd_leases`, and not `/etc/bootptab`: both are denied.

## Virtualization restores a saved state only under its MAC address

Restoring a saved state under a MAC address other than the one it was saved
with fails with `invalid argument` — the failure commit `6c0b3bfc` fixed.
Apple's own sample app pins the MAC address too.

## How other VMMs keep forwarding state

No other VMM surveyed uses vmnet's reservation API. Each that offers port
forwarding keeps the state in its own process — a userspace network stack,
its own daemons, or a proxy — and none of the open-source ones is sandboxed.
Apple's `container` disables vmnet's DHCP
(`vmnet_network_configuration_disable_dhcp`), assigns addresses through an
in-guest agent, and forwards with a userspace proxy.

## Method

1. InternetSharing and bootpd captured with
   `/usr/bin/log stream --level debug --predicate 'process == "InternetSharing" OR process == "bootpd"'`
   during each repro — the daemon's `mis_network_*` lines are debug-level and
   reach no persisted store — timed against Kernova's own `#log` records.
2. `/etc/bootptab` compared before and after each reboot; the guest's
   address from `arp -an` and bootpd's DHCP exchange.
3. Forwarding checked with `nc 127.0.0.1 <host port>` into an in-guest
   `nc -lk <guest port>`.
4. The per-interface rule calls and the standalone-interface control made from
   a development build, each call's return and handler status logged.
5. The crash-relaunch: `kill -9` on Kernova with a Shared Network VM running,
   a relaunch within 3 s, one VM start — 3 s after the kill in one run, 48 s
   in the other.
6. The member runs from a development build holding the member interface
   from a network's first attachment until no VM is on it; in-guest reboots
   from the Apple menu and the GNOME system menu.
7. The ARP table and the two files read from the sandboxed app process.
8. A sysdiagnose after the reservation repro, and the streamed logs, attached
   to FB24895271 and FB24895264.
