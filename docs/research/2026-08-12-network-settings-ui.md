# Network settings UI — end-state design for the advanced-networking rollout

**Date:** 2026-08-12 · **Decided by:** maintainer, from the competitive survey behind #819

Read this when picking up any of #811–#818: it fixes the end-state Network
section UI so each sub-issue implements a slice of one agreed design instead of
redesigning the section per issue. Deviations need a stated reason in the PR.

## The Network section (end state)

```
Network                                            🔒 ⓘ
┌──────────────────────────────────────────────────┐
│ Mode                            Shared Network ⌄ │
│ ─────────────────────────────────────────────────│
│ IP Address                       192.168.64.10 ⧉ │
│ ─────────────────────────────────────────────────│
│ MAC Address       aa:bb:cc:dd:ee:ff   (Generate) │
│ ─────────────────────────────────────────────────│
│ Port Forwarding                                  │
│    TCP   Host 8080 → Guest 80                (−) │
│    TCP   Host 2222 → Guest 22                (−) │
│    (+) Add Rule…                                 │
└──────────────────────────────────────────────────┘

Mode picker menu:
    ✓ Shared Network
      Host Only
      None
      ── Bridged ──────────
      Automatic
      Wi-Fi (en0)
      Ethernet (en1)
```

## Decisions

1. **One Mode picker replaces the "Networking Enabled" switch.** Entries:
   `Shared Network` (default), `Host Only`, `None`, then a `Bridged` menu
   section holding `Automatic` plus one entry per bridgeable interface,
   labeled `localizedDisplayName (identifier)` — e.g. `Wi-Fi (en0)`. `None`
   maps to `networkEnabled == false`; selecting a bridged interface entry sets
   the mode and the interface in one gesture. `Automatic` means the app
   resolves the default-route interface at boot and reattach (Fusion's
   "Autodetect", implemented app-side — VZ itself always takes a concrete
   interface).
2. **Interface list liveness.** The bridged entries rebuild each time the menu
   opens (no separate reload button). An empty list renders one disabled
   `No Bridgeable Interfaces` item. A persisted interface that is currently
   absent shows as `… (unavailable)`; boot falls back to Automatic.
3. **`None` empties the card.** IP, MAC, and Port Forwarding rows are hidden;
   a caption states "This virtual machine has no network device."
4. **IP Address row** shows the copyable address (`CalloutStyle` copy
   affordance). Shared and Host Only display the reserved address — valid even
   while the VM is stopped, since reservations are deterministic; Bridged
   displays "Assigned by your network". The row is absent until the reservation
   machinery exists.
5. **MAC Address row** becomes an editable, `VZMACAddress(string:)`-validated
   field with a `Generate` button (`randomLocallyAdministered`).
6. **Port Forwarding lives inside the Network card**, beneath MAC: one
   hairline row per rule (`TCP  Host 8080 → Guest 80`, borderless remove
   button), a trailing `Add Rule…` row opening a small sheet — Protocol
   (TCP/UDP), Host Port, Guest Port — with add disabled while invalid (empty,
   zero, or duplicate host port) and an inline note on sub-1024 ports. Rows
   are visible only while the mode is Shared Network. The macOS 26
   loopback-forwarding limitation is disclosed in the section's info popover,
   not per row.
7. **Locking while running.** Baseline: the whole section locks as today.
   Once live recovery ships, the picker becomes the live-switch surface: while
   a bridged VM runs, the picker stays enabled with only the Bridged-group
   entries selectable (attachment hot-swap); `None` is always disabled while
   running — network devices cannot be added or removed at runtime. Whether
   live transitions among Shared/Host Only/Bridged are also allowed (hot-swap
   supports them) is decided at #813 pickup.
8. **Creation wizard is unchanged**: the single Networking switch stays; new
   VMs start as Shared Network; the Review step row reads
   `Network: Shared Network` or `Network: None`.
9. **Unentitled builds** (runtime entitlement check fails, dev builds only):
   the picker offers `Shared Network` and `None` — Bridged and Host Only both
   require the entitlement.
10. **Deferred**: surfacing the IP outside the settings form (details-pane
    territory, #80); any app-level networks pane.

## Slice per issue

| Issue | Implements from this design |
|---|---|
| #811 | The unentitled-build picker reduction (9) |
| #812 | Picker replacing the switch (1–3), wizard Review copy (8), popover rewrite |
| #813 | Running-state picker enablement and live interface switch (7) |
| #815 | `Host Only` entry (1) |
| #816 | IP Address row (4) |
| #817 | Port Forwarding rows and the Add Rule sheet (6) |
| #818 | Editable MAC and Generate (5) |

## Method

Decisions taken 2026-08-12 in a planning session with the maintainer, applying
the competitive-UI survey behind #819 (Parallels, Fusion, UTM, and VirtualBuddy
network-pane presentations) to the existing `GroupedFormStyle` section
patterns. The picker shape, wizard scope, live-switch surface, and rules
placement were explicit maintainer choices among presented alternatives; the
single-picker + live-switch pair is reconciled in (7), since with one picker
the interface choice has no separate row to unlock.
