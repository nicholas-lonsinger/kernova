# NETWORKING.md

Read this before picking up any networking issue, and before designing, extending, or
refactoring how a guest attaches to a network or is reached from one — modes, port
forwarding, guest-IP display, MAC handling, attachment recovery. Where this conflicts
with an existing implementation, the implementation is the thing to change; if a
principle here turns out to be wrong, fix it here first, then the code. The end-state
Network section UI is fixed in
[research/2026-08-12-network-settings-ui.md](research/2026-08-12-network-settings-ui.md);
structural facts live in [ARCHITECTURE.md](ARCHITECTURE.md); UI philosophy in
[SPEC.md](SPEC.md).

---

## North star

**The user decides a guest's reach.** Networking gives a guest exactly the network
exposure the user chose for it — nothing more. Kernova's job is to make each choice work
reliably and describe it honestly, never to widen it.

---

## Principles

### 1. A guest is private by default

**Shared Network is the default mode, and nothing widens a guest's exposure to the LAN
without an explicit per-VM user choice** — not a mode change, not a forwarding rule, not
an upgrade, not a recovery path. Reachability from other machines is something the user
turns on, per VM; the app never infers it from context or convenience.

### 2. Recovery restores; it never escalates

**Attachment recovery and Automatic interface resolution re-establish the mode the user
chose.** When the exact choice is unavailable — the persisted bridged interface is absent —
recovery may narrow within that mode (a specific interface falls back to Automatic) but
never widens exposure and never silently substitutes a different mode.

### 3. Forwarding rules bind conservatively

**A new rule exposes the guest port on the narrowest useful listener; anything wider is
an explicit per-rule widening** (Lima's posture). A rule that cannot take effect — a
privileged host port the app cannot bind, a duplicate — is refused or disclosed when the
user enters it, never accepted and left to fail at VM start.

### 4. One forwarding model

**Port forwarding exists once.** Every consumer of forwarding — the Network section's
rules today, any future feature needing port mappings (containers) — uses the same rule
model and the same enforcement path. A second schema for the same capability is a defect
to dissolve, not a variant to maintain.

### 5. Outcome names in the UI; Apple's terms at the platform boundary

**Mode names describe the outcome the user gets** — "Shared Network", "Bridged",
"Host Only", "None" — **and Apple's vocabulary (NAT, vmnet, VZ attachment types) stays in
code and at Apple-facing surfaces.** Where Apple's own UI names the thing (a permission,
an entitlement, a System Settings pane), keep Apple's term at that boundary and the
outcome term everywhere else.

### 6. The IP display claims only what the mode guarantees

**Show an address as fact only where the app controls assignment.** Shared and Host Only
display the reservation-backed address — deterministic, so valid even while the VM is
stopped. Bridged displays "Assigned by your network". Never present a guess — a sniffed
lease, a cached value that may have expired — as knowledge.

### 7. Environment interactions are disclosed at observed strength, where the user meets them

**When the host environment changes what a mode or rule delivers, say so in UI copy —
vendor claims at the vendor's strength, observations as observed, no invented
consequences.** Host VPN interaction with guest traffic, Wi-Fi bridging's MAC-sharing
behavior, the macOS 26 loopback-forwarding limitation (Apple DTS: "a known limitation of
vmnet", FB7731708) — each is disclosed at the surface where the user hits it (the
section's info popover, an entry-time note), not repeated per row and not escalated into
consequences no one observed.

### 8. Capability degrades by absence

**A build that cannot deliver a mode does not offer it.** An unentitled build's picker
omits Bridged and Host Only rather than presenting entries that would fail; the modes
the build can deliver keep working unchanged. Absence is the honest degraded state —
never a visible-but-broken control.
