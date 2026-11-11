# NETWORKING.md

Read this before changing how a guest attaches to a network or is reached from one.

## Exposure is the user's choice

A guest gets the exposure the user chose for it, per VM: no mode change, decode
fallback or recovery path attaches a mode or a network the user did not choose.
Recovery stays inside the chosen mode — a Bridged VM whose interface is gone bridges
over the host's default-route interface — and a network that cannot be made leaves
the guest detached until it can. Worked case: `NetworkAttachmentCoordinator`.

## An address is stated at the strength of its source

Show a guest address only as what the app saw: the address the host last saw the
guest use, while that sighting is current. Where the app sees none, say who assigns
it or say nothing. Given a source that would fill the gap — a lease read from
elsewhere, an entry past its expiry — leave the gap. Worked case: `GuestIPAddress`.

## A MAC address belongs to one virtual machine

Given a bundle that arrives with an address another VM holds, admit it and disclose
it rather than rewrite or refuse it: the guest may pin the address, and a LAN's DHCP
server may hold a reservation for it. Two holders never run on one network at once,
and no confirmation waives that. An address a VM's snapshot was taken with stays that
VM's until the snapshot is deleted, because a revert puts the VM back on it
([VZ restore requires the saved MAC address](research/2026-09-23-vz-restore-requires-the-saved-mac-address.md)).
Worked case: `VMMACAddressRegistry`.

## Guest-to-guest reach is network membership

On NAT and Host Only, a guest reaches another guest exactly when the user placed both
on the same app-managed network: separate networks do not reach each other
([separate vmnet networks isolate their guests](research/2026-09-30-separate-vmnet-networks-isolate-their-guests.md)).
Given a stricter or different grouping to express, add a network, not a mode variant
or a per-interface isolation flag. Worked case: `VMNetworkMembership`.
