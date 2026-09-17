# NETWORKING.md

Read this before changing how a guest attaches to a network or is reached from one.

## Principles

### 1. Exposure is the user's choice; recovery restores it, never widens or substitutes

**A guest gets exactly the exposure the user chose for it, per VM.** Nothing widens it
without that choice — not a mode change, a forwarding rule, a decode fallback, or a
recovery path. When the exact choice is unavailable, recovery narrows within the chosen
mode (a persisted bridged interface that is gone falls back to Automatic) or runs
detached until it returns; it never attaches a mode the user did not choose.

### 2. Refuse at entry what cannot take effect

**A value the guest can never use is refused, or disclosed, where the user enters it** —
a forwarding host port another VM already claims, a MAC address no frame can source, a
share path that is not a folder — never accepted and left to fail at the next start.

### 3. An address is stated as fact only where the app assigns it

**Show a guest address as knowledge only when the app controls its assignment.** Where
something else assigns it, say so; never present a guess — a sniffed lease, a value that
may have expired — as the address.

### 4. A MAC address belongs to one virtual machine

**The app never authors a second holder of an address, and never rewrites or refuses
one a bundle arrives with** — the guest may pin it, and a LAN's DHCP server may hold a
reservation for it — so import, load and reconcile admit the duplicate, the VM's Network
section names the other holder while the address stays editable, and two holders never
run on one network at once: the second to start is refused.

### 5. Guest-to-guest reach is network membership

**A guest reaches another guest exactly when the user placed both on the same
app-managed network.** Isolation is expressed by membership — separate networks are
mutually isolated — never by a per-VM flag; a stricter grouping is a new network, not a
mode variant.
