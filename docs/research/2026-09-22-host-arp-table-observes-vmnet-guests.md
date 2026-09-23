# The host's ARP table observes a vmnet guest's address

**Date:** 2026-09-22 · **Host:** M1 Max, 32 GB, macOS 27.0 (26A428) ·
**Binary:** a development build signed with `com.apple.vm.networking` and
`com.apple.developer.networking.topology-observation`, sandboxed, whose vmnet
networks installed no DHCP reservations and no forwarding rules · **Guests:**
macOS 27 and Ubuntu Desktop 26.04 on Shared Network

## Summary

The sandboxed app reads the host's IPv4 ARP table through the routing sysctl
`{CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO}`, and the table
holds a vmnet guest's address keyed by the guest's MAC address about one
second after bootpd acknowledges its lease. What the app read matched
`arp -an`. The entitlement the read needs on macOS 27 is recorded in
[2026-09-22-vmnet-network-run-and-forwarding-rules.md](2026-09-22-vmnet-network-run-and-forwarding-rules.md#what-a-sandboxed-process-can-read).

- **Timing.** A guest's entry appeared at the first read after bootpd's
  `ACK sent`: 1.2 s after it for the macOS guest (18:08:13.677 → 18:08:14.837)
  and 0.8 s for Ubuntu (18:18:45.931 → 18:18:46.718), each reported with its
  full 1200 s lifetime. The ACK came 6.2–7.2 s after `Started VM` across
  three starts.
- **Expiry.** An entry's expiry moves only when an ARP frame arrives from the
  guest, which sets it 1200 s out; host sends and other IP traffic leave it
  where it is. One guest's expiry moved 1_790_126_897 → 1_790_126_957 between
  two reads a minute apart. `rtm_rmx.rmx_expire` is a Unix time, comparable
  with `time(nil)`.
- **An expired entry stays listed.** An entry on `en0` was still returned
  680 s past its expiry, and still at 686 s on the next read, so expiry has to
  be checked; presence alone says nothing.
- **Permanent entries.** The host's own address on the bridge
  (`192.168.65.1`) and multicast groups (`224.0.0.251`) are listed with expiry
  `0`.
- **Network stop flushes the bridge.** When the last VM left, InternetSharing
  logged `no internal interface left, stopping network`, and the next read held
  no entry on the bridge.
- **Addresses held without reservations.** bootpd re-issued each MAC the
  address `/var/db/dhcpd_leases` already held for it on that subnet across
  network recreates and an app relaunch: `2e:43:28:63:bc:2d` got
  `192.168.65.16` and `96:d6:b3:11:6c:26` got `192.168.65.10`, both entries in
  the lease file before the run. The file keys each MAC's address per subnet —
  `2e:43:28:63:bc:2d` also held `192.168.64.111`.

## Method

1. A development build read the table every 5 s from launch and logged each
   entry — address, MAC, interface, expiry and seconds remaining — and which
   library VM's MAC it matched.
2. Kernova's, InternetSharing's and bootpd's records captured with
   `/usr/bin/log show --predicate 'subsystem BEGINSWITH "app.kernova" OR process == "InternetSharing" OR process == "bootpd"'`,
   timing each first match against bootpd's `ACK sent` and Kernova's
   `Started VM`.
3. `arp -an` compared against the app's read with a guest running.
4. `/var/db/dhcpd_leases` copied before the run and compared with the address
   each guest was seen at.
5. Guests started, force-stopped, restarted and relaunched across two app runs.
6. XNU's `bsd/netinet/in_arp.c` (apple-oss-distributions/xnu) read for every
   write of an entry's expiry: only `arp_ip_handle_input`, handling a received
   ARP frame, extends it, to `net_uptime() + arpt_keep` (20 min).
