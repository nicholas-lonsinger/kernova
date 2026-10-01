# Separate vmnet networks isolate their guests; one process holds up to 255

**Date:** 2026-09-30 · **Host:** M1 Max (MacBookPro18,4), 32 GB, macOS 27.0.1
(26A434), Xcode 27.0 · **Binary:** the KernovaTests host, a Debug build of
`0c6e7e03` signed with `com.apple.vm.networking`, sandboxed · **Guests:** none;
every endpoint is a raw interface from `vmnet_interface_start_with_network`
driven with `vmnet_read`/`vmnet_write` — except the restore section, which ran a
macOS 26.6.2 guest under a Debug Kernova build carrying a VM's own network,
driven by that build's `kernova` tool · **Tracking issue:** #1459

## Summary

- One sandboxed process creates up to **255** vmnet networks across both modes.
  Left to the system, Shared takes `192.168.64.0/24`–`192.168.127.0/24` and
  Host Only `192.168.128.0/24`–`192.168.191.0/24`, 64 each, in ascending
  order; the 65th fails with `VMNET_FAILURE` (1001). A subnet set with
  `vmnet_network_configuration_set_ipv4_subnet` takes any private block
  (`10/8`, `172.16/12`, `192.168/16`, `/16` to `/28` accepted) and is refused
  for a public one (`8.8.8.0/24`) or one already held. With 64 system-picked
  Shared networks held, 191 pinned ones succeeded and the 192nd failed, after
  which neither a system-picked Host Only network nor any pinned one could be
  created.
- **Two vmnet networks do not reach each other.** An endpoint on one Shared
  network sending ICMP echo through its gateway to an endpoint on another
  Shared network, or between a Host Only and a Shared network, delivered
  nothing — 0 of 3 echoes, in both directions, in two runs — while the gateway
  itself answered and two endpoints on one network exchanged every echo. The
  host has `net.inet.ip.forwarding: 1` throughout.
- **`vmnet_enable_isolation_key` isolates nothing on a network made by
  `vmnet_network_create`.** Two interfaces started with the key set to `true`
  on one network exchanged ARP and every ICMP echo, directly and through the
  gateway, in both directions; so did an isolated and a non-isolated one.
  `VZVmnetNetworkDeviceAttachment` exposes no interface descriptor in any case
  (its only initializer is `initWithNetwork:`), so a VZ guest's isolation is
  its network's membership.
- **One MAC address leases on two networks at once.** bootpd keys a lease by
  client and subnet: the same MAC (`02:14:59:00:00:03`) took `192.168.64.153`
  on one network and `192.168.65.27` on the other, `/var/db/dhcpd_leases` held
  both entries, and RENEWING-state requests on each were ACKed in every
  interleaving, including after the other side rediscovered.
- **A network costs nothing on the host until an interface joins it.** 64
  created networks with no interface added no host interface. A running
  network is one `bridgeN` plus one `vmenetN` per interface, and InternetSharing
  starts a DNS proxy for it. 40 networks, each with one member, raised
  InternetSharing's RSS from 8.5 MB to 9.5 MB; its CPU rose only while networks
  started and stopped, and was 0.0% with all 40 running.
- **A saved state restores onto a different network of the same mode.** A
  guest suspended on one Shared network (`192.168.66.0/24`) restored onto a
  newly created Shared network on another subnet (`192.168.65.0/24`), and
  answered there.

## Restore onto a different network of the same mode

| Step | Network the guest is on | Observed |
|---|---|---|
| Cold boot | Shared, created by the copy (`192.168.65.0/24`) | address `192.168.65.6` |
| Live attachment swap to a network of its own | Shared, new (`192.168.66.0/24`) | address `192.168.66.4` within 4 s |
| Suspend, quit the copy | — | the `192.168.66.0/24` network released |
| Relaunch, resume | Shared, new (`192.168.65.0/24`, the lowest free subnet) | restore succeeded in 4.1 s; address `192.168.65.6`; 3 of 3 host pings answered |

The first Shared network landed on `192.168.65.0/24` because another running
copy of Kernova held `192.168.64.0/24`. Kernova refuses a network change on a
suspended VM, so the move between networks was made across the relaunch, which
creates every network anew.

## Capacity and subnets

| Request | Result |
|---|---|
| System-picked Shared, repeatedly | 64 created, `192.168.64.1/24` … `192.168.127.1/24`, 3–8 ms each after the first (222 ms); the 65th: 1001 |
| System-picked Host Only, repeatedly (Shared all released) | 64 created, `192.168.128.1/24` … `192.168.191.1/24`; the 65th: 1001 |
| Pinned `10.77.0.0/24`, `10.78.0.0/16`, `172.16.40.0/24`, `192.168.200.0/24`, `192.168.201.0/28` | created |
| Pinned `8.8.8.0/24` | 1001 |
| Pinned `10.77.0.0/24` while the first is held | 1001 |
| 64 system-picked Shared held, then pinned `10.80.N.0/24` | 191 created; the 192nd (`10.80.191.0/24`): 1001 |
| Then one system-picked Host Only, one pinned `172.20.0.0/24` | both 1001 |

`vmnet_network_get_ipv4_subnet` returns the host's address on the subnet
(`192.168.64.1`), not the network address, with the mask. Releasing 64 idle
networks took 7–8 ms.

## Reach between networks

Each endpoint holds a static address and answers ARP and ICMP echo for it.
"Via gw" sends to the gateway's MAC, resolved by ARP on the sender's network.

| From → to | Path | Echo requests the target received | Replies |
|---|---|---|---|
| A → host (`192.168.64.1`) | direct | — | 1 of 1 |
| A → B, both on Shared N1 | direct | 3 of 3 | 3 |
| A on Shared N1 → C on Shared N2 | via N1 gw | 0 of 3 (two runs) | 0 |
| C on Shared N2 → A on Shared N1 | via N2 gw | 0 of 3 | 0 |
| H on Host Only N3 → A on Shared N1 | via N3 gw | 0 of 3 | 0 |
| A on Shared N1 → H on Host Only N3 | via N1 gw | 0 of 3 | 0 |
| I1 → I2, both isolation key `true`, N1 | direct, both directions | 3 of 3 | 3 |
| I1 → I2 | via N1 gw | 3 of 3 | 3 |
| I1 (isolated) → B (not) | direct | 3 of 3 | 3 |

## Host cost of running networks

Sampled once a second with `ifconfig -l` and `ps -axo rss=,pcpu=,comm=`:

| State | Bridges (besides `bridge0`) | `vmenet` | InternetSharing |
|---|---|---|---|
| 64 networks created, no interface | 0 | 0 | 8.5 MB |
| 40 networks, one member each | 40 | 40 | 9.5 MB, 0.0% CPU |
| Stopping the 40 | — | — | 45.9% CPU for under a second per batch |

Starting the 40 sequentially, create plus member start, took 8.96 s. Every
interface stopped and network released left no bridge behind.

## Method

1. A Swift Testing suite in KernovaTests, run with `make test-suite`, so the
   calls come from the entitled, sandboxed app process. It creates networks
   with `vmnet_network_configuration_create` and `vmnet_network_create`, and
   starts endpoints with `vmnet_interface_start_with_network`, passing
   `vmnet_enable_isolation_key` and, for the DHCP rows,
   `vmnet_allocate_mac_address_key: false` with a chosen source MAC.
2. Endpoints build Ethernet, ARP, IPv4, ICMP and BOOTP frames by hand, write
   them with `vmnet_write`, and read with `vmnet_read` from the
   `VMNET_INTERFACE_PACKETS_AVAILABLE` callback.
3. DHCP: DISCOVER, OFFER, REQUEST (SELECTING), ACK on each network; then
   RENEWING-state requests unicast to the gateway with `ciaddr` set, as a guest
   renews. A unique MAC on one network is the control.
   `/var/db/dhcpd_leases` copied while both leases were held.
4. `/usr/bin/log stream --level debug` for InternetSharing and bootpd, and the
   suite's own lines, throughout.
5. `ifconfig -l` and `ps` sampled every second for the cost table.
6. Restore: an Ephemeral Mode VM driven with `kernova start`, `set
   network.isolated=true` while running, `suspend`, `quit`, then `resume` from
   a fresh launch; the address read with `kernova ip`, reachability with
   `ping`, and network creation, release and the restore with
   `/usr/bin/log stream` over the copy's own records.

## Not measured

- Whether the 255-network ceiling is per process or shared by every vmnet
  client on the host: a second entitled process creating networks while the
  first holds 255.
- A restore onto a different Host Only network; the restore above was Shared
  to Shared, alongside the attachment-kind changes in
  [VZ restore matches](2026-09-30-vz-restore-matches-machine-shape-and-device-set.md).
- Two VZ guests sharing a MAC address on two networks. The endpoints above
  source the MAC in their own frames; VZ sets a guest's MAC on its interface.
