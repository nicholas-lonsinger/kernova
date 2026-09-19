# A vmnet network serves its DHCP reservations for one run

**Date:** 2026-09-18 · **Host:** M1 Max, 32 GB, macOS 27.0 (26A428) ·
**Binary:** `/usr/libexec/InternetSharing`, arm64e slice

## Summary

A network made by `vmnet_network_create` from a configuration carrying DHCP
reservations serves them for its first run only. InternetSharing, the daemon
behind a vmnet network's DHCP server, writes the reservations of every network
in a starting or running state to `/etc/bootptab`. Stopping a network moves it
out of those states, rewrites `/etc/bootptab` without it, and frees its
reservation list. A later start of the same `vmnet_network_ref` finds no list,
writes nothing, and `bootpd` hands the guest a dynamic lease from the pool.

A network stops when its last VM's interface leaves it; a VM leaving while
another remains stops nothing, and a VM joining a running network leaves
`/etc/bootptab` as it is. A stopped network goes idle rather than away: it is
torn down when its ref is released, and until then the same ref can start it
again.

## The stop, observed

Captured live on 2026-09-18 with `/usr/bin/log stream --level debug`, against a
development build that keeps an idle network and replaces it as the next VM
joins, running Ephemeral Shared VMs:

- The last VM leaving a network logs the stop, and `/etc/bootptab` is emptied
  at that moment — one stop logged at 21:20:46, the file written at
  21:20:46.88:

  ```
  mis_network_cleanup_bridge: … no internal interface left, stopping network
  mis_network_stop: network … reset to idle
  ```

- Kernova releasing its ref on the idle network logs its teardown, in the same
  millisecond as Kernova's `Invalidated the shared network` (21:21:24.373 in
  one case):

  ```
  netrbRemoveNetwork: stopped idle network
  mis_network_stop: … has been stopped
  ```

- A second VM joining a running network logs `adding interface to existing
  network` and leaves `/etc/bootptab` untouched. A VM leaving while another
  remains logs only `netrbRemoveInterface`, with no stop.

Six restarts or tight stop-then-start cycles each released the idle network and
created its successor, pinned to the same subnet, within 55–77 ms, and each
guest's DHCP ACK carried its reserved address. The shortest gap from a network
going idle to its replacement was 0.96 s, floored by the Ephemeral revert
between runs; a replacement less than a second after the stop was not
observed.

## Lease evidence

Kernova reported `192.168.65.10` (reservation slot 8 on the shared network) for
the VM whose MAC is `22:59:b6:af:b4:ea`. The host's DHCP state disagreed:

| File | State |
|---|---|
| `/var/db/dhcpd_leases` | `22:59:b6:af:b4:ea` holds `192.168.65.15`, `lease=0x6aab2e99` — expiring 2026-09-16 17:04:41 PDT, one hour after the file's 16:04:41 write: a dynamic one-hour lease |
| `/var/db/dhcpd_leases` | `192.168.65.10` held by another VM (`96:d6:b3:11:6c:26`), expired 2026-09-13 14:23:20 PDT |
| `/etc/bootptab` | 0 bytes, last written 2026-09-16 16:04:33 PDT and not since |

So `/etc/bootptab` was emptied eight seconds before the guest's lease was
granted, and the guest got no reservation. Kernova held one network object
across both moments: it cached each materialized network until the app exited,
so the boot that took the lease ran on the network created with the
reservation.

## InternetSharing

`otool -arch arm64e -tV /usr/libexec/InternetSharing`:

- **`0x100017e84`**, the function whose error path logs
  `dhcp_bootptab_refresh`, opens `/etc/bootptab` with mode `"w"` and walks the
  global network list. At `0x100017ed8` it loads each network's state word
  (offset `0x128`) and skips every network whose state is neither 1 nor 2; for
  the rest it prints one `client%llu 1 %02x:%02x:%02x:%02x:%02x:%02x %s` line
  per node of the reservation list at offset `0x1d8`.
- It has two callers, both conditional on the network's reservation list being
  non-null: **`0x100017a54`**, on the start path right after
  `dhcp_config_create`, and **`0x100018088`**, in the refresh the stop path
  calls.
- The stop routine sets the state word at **`0x100004490`–`0x1000044ac`**: a
  network in state 1 or 2 whose flags word (offset `0x8`) masked with `0x110` is
  `0x100` goes to 0, any other to 4. It then calls the refresh at `0x100004628`
  — with this network already out of states 1 and 2, so its reservations are
  omitted — and frees the reservation list node by node at
  **`0x10000462c`–`0x100004640`**, leaving offset `0x1d8` null.
- A later start of that network reaches `0x100017a54` with a null list, so
  nothing is written for it.

Inferred rather than read from the binary: states 1 and 2 are starting and
running, 0 is idle, and flags `0x100` without `0x10` marks a network created
through the vmnet API — the values carry no names. `mis_network_stop: network …
reset to idle` is this routine running.

A network created anew from a configuration carrying the reservations enters
the start path with a non-null list, so its first run serves them.

## Method

1. `stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' /etc/bootptab /var/db/dhcpd_leases`
   and `wc -c /etc/bootptab` for the write times and the empty table.
2. The lease entries read from `/var/db/dhcpd_leases` directly; `lease=` is the
   expiry as a hexadecimal Unix time, decoded with `date -r $((0x6aab2e99))`.
3. `otool -arch arm64e -tV /usr/libexec/InternetSharing`, located by the
   `/etc/bootptab` literal-pool reference, with every `bl 0x100017e84` in the
   listing taken as the caller set.
4. InternetSharing's lines captured live with `/usr/bin/log stream --level
   debug` while VMs started, stopped and restarted, timed against Kernova's own
   records and the `/etc/bootptab` write time. They are not in the persisted
   store: a later `log show --last 6h` found neither `stopping network` nor
   `stopped idle network`.
