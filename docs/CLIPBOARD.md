# CLIPBOARD.md

Read this before designing, extending, or refactoring any clipboard code, and before picking up
any clipboard issue. Where this conflicts with an existing implementation, the implementation is
the thing to change; if a principle here turns out to be wrong, fix it here first, then the code.
Structural facts live in [ARCHITECTURE.md](ARCHITECTURE.md); UI philosophy in
[SPEC.md](SPEC.md).

## Scope

- **In scope:** macOS host ↔ macOS guest clipboard sharing over the vsock streaming transport.
- **Out of scope:** Linux guests (the separate text-only SPICE path) and Windows guests. Their
  size and behavior targets must not constrain the macOS↔macOS design.
- **The reference target is native macOS.** The yardstick for every decision: *what would this
  copy/paste do if both ends were the same Mac?* Match that on capability; match or beat it on
  resource cost. For the cross-boundary behavior the model is Universal Clipboard between two
  devices — advertise metadata on copy, transfer the bytes on demand at paste. Never an eager
  broadcast.

**"On demand at paste" is not a platform guarantee — it is ours to build.** The guest's
continuity-pasteboard advertiser (`useractivityd`, via pboard's remote layer) fetches a promised
`public.file-url` flavor from the publishing provider on **every new pasteboard generation**,
independent of paste and of Apple Account state — observed live 2026-07-16 on a guest with no
Apple Account signed in, `useractivityd`/`sharingd`/`rapportd` all running. It is
account-independent OS infrastructure, not Universal Clipboard the feature.

---

## North star

**Our job is to facilitate the copy/paste — nothing more, nothing less.** We move the content
across the boundary with the least possible Kernova-added overhead and the most native-feeling
experience. We do not editorialize, we do not protect the user from a large transfer they chose to
perform, and we do not impose limits macOS itself would not.

---

## Principles

### 1. No Kernova-imposed size bound

**If a copy/paste works natively on macOS, it must work host↔guest through Kernova — at any size,
for every representation.** Any fixed ceiling in the transport is a Kernova artifact and a defect
to dissolve, not a feature to preserve.

- **Residency is an implementation detail, never a reason to cap.** Whether a representation's
  bytes live in RAM, on disk, or in a memory-mapped file must not change *whether the paste
  succeeds*. The inline-vs-file distinction describes the **pasteboard flavor the destination
  receives**, not where the bytes sit — back a large "inline" representation with streamed or
  mmapped storage so there is nothing left to cap.
- A residual cap is acceptable only where a **host-OS deadline** derives it (§2).

### 2. Disk staging is a fallback, not the default

**Match macOS's own residency.** If a native copy/paste of this content would not touch disk,
prefer a path that does not either. Reach for disk only when the destination is genuinely a file
or the payload cannot responsibly stay in RAM — never as a reflexive intermediate copy. Preferred
mechanisms, in order:

1. **Direct streaming into the served representation** for inline types, not a disk round-trip.
2. **Bounded disk/mmap staging** when the destination is genuinely a file, and as the spill for
   inline data too large to sit resident in RAM.

**Kernova's own on-disk footprint for a transfer must approach zero beyond the destination file** —
which the destination write does not violate, since native pays it too. An intermediate that
scales with payload size is a defect to dissolve, and a serialized container is no exception:
serializing a file or a tree (§6, §11) must *itself* stream, source → archive bytes → wire →
extracted destination, with no full-size archive landing whole on disk at either end and no
extracted payload left coexisting with its archive. Integrity (§7) is kept by hashing **inline**
as bytes stream.

Caveats this does **not** waive:

- The **synchronous pasteboard provider API has no "still working" signal**: a promised flavor's
  bytes are pulled inside the consumer's provide callback, which cannot return until they exist,
  against an OS paste deadline nothing can signal into or extend. Reserve direct-to-RAM pulls for
  inline content that comfortably fits.
- **That deadline derives the one residual cap §1 admits** — a bound on the **total** of one
  paste's file representations, identical in both directions. The OS clock sees one paste as one
  operation, not each file, so an over-cap offer is **refused whole**, at the Copy to Mac click
  where one is in play, never delivered as a piecemeal subset. It is a permanent constraint of
  serving pastes through this API, not a defect to dissolve. The user selects it from a bounded
  ladder; the derivation of the default, and the ladder itself, live on `ClipboardPasteLimit`.
- **The cap is enforced by the receiver, once per direction** — the side whose paste deadline is
  at risk. The guest gates host→guest, the host gates guest→host, and neither caps what it
  *sends*. So the host pushes the value in `PolicyUpdate` to keep the guest's copy tracking the
  user's choice; what the *guest* will apply must never clamp the host's own ceiling, which no
  peer is party to.
- **Keep the two directions symmetric.** A capability that makes a payload lazy-eligible one way
  must make it lazy-eligible the other.

### 3. Pay on consume (the governing invariant)

**Bytes cross the host↔guest boundary only when a destination consumes them — a paste, or the
window's bounded preview (§5). Every earlier moment — the copy, the offer, a passthrough
auto-publish, the Copy to Mac click — handles metadata only.** Never read, hash, copy, archive,
or materialize a payload before that moment.

- **Routing is pay-on-consume too**: how a representation is served — cached bytes or a fresh
  pull, resident or staged — is decided inside the provider closure on the first real paste, in
  both directions; never at offer time, never when a Copy button is clicked.
- **Registration must be cheap for *every* flavor a publication exposes** — the OS fetches
  promised flavors on its own schedule (Scope), while a promise's fulfillment runs the full pull.
  What squares those is the unconditional `.currentHostOnly` scope (§10): the advertiser never
  processes the write, so no fetch fires without a real paste. A flavor that cannot ride that
  protection must not be registered.
- **Serializing a file or directory into an archive is materialization.** The offer carries the
  file's stat size or the folder's stat-walk estimate and retains the source itself; the archive
  is built only when a paste requests the representation, bounded by the cap (§2).
- **Do not evict a served artifact after its paste**; removal stays scoped to supersession. A
  fulfilled provider never re-fires, so deleting the staged file behind a vended `public.file-url`
  dangles the pasteboard's cached URL and breaks a second paste of the same content.

### 4. One data plane; gating is a checkpoint, not a fork

**Gated (clipboard window) and passthrough modes must share a single data path.** They differ only
in *when* consume is triggered — gating inserts an explicit-intent approval step — never in *how*
bytes move. There must be no second, parallel transport: a new mode changes who authorizes the
pull, not the pull itself.

- The gate's purpose is **trust** (§10), not transformation. Passthrough does not waive §3 — its
  auto-publish reuses the same lazy promise write — and enabling it requires explicit confirmation.
- With passthrough on for several VMs the host pasteboard is genuinely shared across them; that
  must terminate rather than loop, each guest agent suppressing its own echo.

### 5. The window is a preview; the preview is never on the data path

**The clipboard window renders a bounded, cheap preview and nothing more.** The preview decision
must never influence the bytes that pass through — content delivered to the destination is
identical with or without gating.

A preview must be derivable **cheaply**: header-only metadata, a size-capped thumbnail decode, or
a placeholder for anything too large to render cheaply. A bounded preview-pull is allowed; it must
never escalate into a full materialization. **A preview and a paste for the same representation
share one pull** — neither displaces the other, the second joins the first — so the preview's own
bound is also what keeps a joined paste's wait short against the deadline (§2).

### 6. Fidelity: preserve every representation, resolve at paste time

**Clipboard content is a set of representations (text, RTF, image, file URL, …), not one blob.**
Preserve **every** representation the source offered and choose which to hand over at the moment
the destination asks. Dropping one — losing an inline image when syncing rich text — is a fidelity
defect; round-trip equality with a native copy/paste is the bar.

- **Every copy replaces what the peer holds — including one that carries nothing.** A native
  copy makes the previous pasteboard unreachable, so an offer filtering left empty — whatever
  filtered it — *releases* the peer rather than leaving it advertising content the user has
  already replaced. Only a release clears the peer's pasteboard write; an empty offer retires
  the promise and leaves that write behind it unservable. A snapshot an `org.nspasteboard.*`
  marker suppressed is not a copy and releases nothing.
- **File and folder fidelity rides the archive's field-key set.** Every file and folder crosses
  as an archive — a folder of its tree, a file of its one entry — and what survives the round
  trip is exactly what `ClipboardArchive`'s key set carries. Changing that fidelity means
  changing the key set, never bolting metadata on through a side channel.
- **Accepted gap: extended attributes cross on *no* paste path** — Finder tags,
  `com.apple.quarantine`, `kMDItemWhereFroms`: the key set omits `XAT`, so the gap is uniform by
  construction and closes, if it closes, for every path at once. One path carrying them alone
  would be a worse inconsistency than dropping them everywhere.
- **Do not chase destination-added metadata as a Kernova fidelity bug.** Finder stamps
  `com.apple.FinderInfo` on bundle-named directories it creates during a copy, which
  `codesign --verify --strict` reports as detritus on an otherwise byte-identical bundle (verified
  2026-07-20: it passes after `xattr -cr`, and a plain `cp -R` diverges the same way).

### 7. Integrity is not negotiable for speed

The vsock transport has **no CRC**; the end-to-end SHA-256 verification is the *only* corruption
detector. **It stays.**

- Optimize by removing **redundant** work — re-hashing bytes already hashed — never the only
  correctness check. **Overlapping** the check with other stages is fair game; *skipping* or
  deferring it past delivery is not.
- The ordering constraint is absolute: no representation reaches a consumer until size and SHA-256
  have both been verified and the staging file committed. A digest mismatch aborts before anything
  is delivered and before any timing metric is reported.
- A change that weakens a correctness or integrity guard is rejected by default, including the
  digest-based echo suppression and dedup, which must stay correct under concurrency.

### 8. Keep the latency-sensitive thread free

The host main actor and the guest run loop are latency-sensitive. **They must never block on work
that scales with payload size** — hashing, copying, archiving, or disk I/O. Serving the OS's
synchronous promise callback (§2) occupies whichever thread the OS delivers it on until the pull
resolves, and **on the main thread that wait runs the application's event loop** rather than
parking: the app keeps drawing, dispatching input and running main-queue work — the readout §13
owes included — while the pull's payload-scaled stages run elsewhere, and a failed or superseded
transfer wakes it immediately (§9). That wait is reentrant by design: a supersession, a stop, or
a second promise callback can land inside it, so a pull a callback owns must be visible to every
other requester of its transfer id, and state captured before the wait is checked against the
live offer after it. It nests only at the base of the main run loop — inside a tracking or modal
loop, which owns the events, the fire is refused and reported (§13) rather than served, because
the main thread is never parked; only an off-main caller parks, and nothing that resolves such a
wait may be routed through the parked thread — and whatever on this side reads
a promised flavor of Kernova's own write does so from that base, as an event or a run-loop timer,
never from a main-queue callout, whose drain the nested loop cannot re-enter.

- **A flow-control size and a safety bound are never the same constant.** The quantum an extract
  re-checks its free-space and payload ceilings on (`extractPacingBytes`) decides how far a
  transfer overruns them before the next check. Derive it from a throughput lever — the socket
  buffers the kernel meters the stream with, or `dataSendBufferBytes` — and tuning throughput
  silently coarsens a guard.

### 9. Abort and restart must be immediate, idempotent, and bidirectional

**A dropped, superseded, or failed transfer must wake any parked pull immediately** — never leave
it stalling until a backstop timeout, which is a last resort, not the cancellation path.

- Aborts propagate both ways and resolve **idempotently**; a late duplicate abort is harmless.
- **An abort rides the transfer's own connection, never a frame beside it.** A sender's reason is
  the trailer that ends its payload stream; a receiver's is the close, which carries no reason and
  needs none. In band is what keeps a reason from overtaking or trailing the bytes it explains,
  leaving neither side a race to arbitrate.
- **A transfer id stays derivable from `(generation, repIndex, direction)` alone.** Cancellation
  re-derives the id rather than remembering it, and the cancel race guard depends on that
  determinism — do not make the id format vary per attempt.
- Restart after abort must be cheap: no orphaned state, no leaked staging, no connection left open.

### 10. Trust boundary and privacy

**The guest is untrusted.** The host must not expose its clipboard to a guest absent the sharing
toggle and (in gated mode) explicit user intent; gating (§4) is that explicit-intent boundary.

- **Honor pasteboard privacy markers.** Transient / auto-generated snapshots (`org.nspasteboard.*`)
  are not synced. Concealed (password) content may sync, but its bytes must never reach a view.
- **Every clipboard pasteboard write, on either side, is `.currentHostOnly`, unconditionally** —
  neither inbound guest content nor host-originated content may be re-advertised onward, and the
  scoping is also what stops the continuity advertiser fetching promised flavors at offer time
  (§3). Verified 2026-07-16: a 1.5 GiB promised offer sat 160 s with zero bytes pulled, and a
  real paste still streamed immediately.
- **Feature-channel admission is gated on the per-VM control handshake.** A feature listener
  refuses a connection while no control channel with a completed `Hello` exists for that VM, and a
  feature channel carrying another port's payload is closed.
- **Do not add a delivered per-VM secret.** Any secret the unprivileged guest agent could present
  is readable by every other unprivileged in-guest process — the very peer it would need to
  exclude — so it adds delivery and reinstall churn without adding defense. Revisit only if the
  guest gains an internal privilege boundary.

### 11. Sandbox-forward by construction

**New clipboard code must be written to be sandbox-safe from the start** — never reworked toward
it later. Beyond AGENTS.md's sandbox rules: archive with AppleArchive, never `ditto`/`tar`/`zip`.

### 12. Complexity is an acceptable price for a measurable win

When a simpler implementation and a more sophisticated one differ on a **real metric** — disk,
memory, I/O, CPU, or UX — **take the sophisticated one.** The guard is **"measurable"**:
complexity that does not move a real metric is just complexity, and is rejected.

### 13. Making slow work legible

**Surface progress for any non-instant transfer, in both directions.** Terminal states —
completion, error, abort — must clear the indicator; never leave a stuck bar. Progress UI is
necessary but not sufficient: the OS paste deadline cannot be signaled into (§2), so a bar never
substitutes for the cap that keeps a paste inside it. **Report a refusal on the side that made the
gesture**, since the user owed the message is the one who acted. **A refusal belongs to the VM, not
to the connection that raised it** — a promise outlives the service that published it (§3), so every
surface renders the per-VM record rather than a live service's own property.

**One item the sending side cannot read never cancels the batch.** A gesture over several items
delivers the ones it can — whether the item is unreadable before the offer or turns out to be once
the peer asks for it — and the refusal names how many were left out. The receiving side skips what
it is told it cannot have and keeps going; a batch that delivers nothing at all is the only one
reported as delivering nothing.

**Progress is aggregate per operation, never per file.** An operation is one
user-visible gesture — a paste, a Copy to Mac, a preview fetch, a drop, one side
serving a peer's pulls — and its bar climbs once, whether its transfers run
sequentially or concurrently.

- **One value per peer**, running or finished, that every surface renders. Both
  directions and every producer for that peer publish into it. It shows the
  gesture someone is waiting on ahead of one they can walk away from, ties by
  recency; an app-level readout spanning several peers ranks them the same way
  rather than keeping a registry of its own.
- **What the one value leaves out is still counted on it.** An operation the peer
  has accepted but not started, and a second one running where only one bar fits,
  are both work the user asked for: carry their number on the readout, so a queue
  reads as a queue instead of as nothing at all.
- **A Cancel stops what its own readout showed.** The readout is the user's only
  handle on a transfer, so the affordance carries the identity of the operation it
  was rendered for. Resolving one at click time reaches whichever transfer is
  newest by then, which is not the one they were looking at.
- **Evaluate the reveal delay on each event, not from a timer**, so an operation
  finishing inside the gate never flashes UI and one stalled before its first
  byte shows nothing rather than a frozen bar. Emission past the gate is
  throttled, so a folder of thousands of small files repaints at a rate a screen
  is worth.
- **A terminal always clears the indicator.** Completion and cancellation leave
  the bar where they stopped it for a beat, so a long paste reads 100 % rather
  than vanishing at 99 % and a cancel is visibly what happened. A refusal is a
  finished report carrying the gesture that produced it, and its wording is
  derived once from that pair rather than composed per surface.
- **Only a surface that interrupts gets a stricter bar.** A menu that opens
  itself takes over the screen: open it only for a gesture someone is waiting on
  — a peer's paste, which holds the app it is pasting into, and a drop, whose
  files are not in the guest until it lands — only once, only after the operation
  is worth interrupting for, and only while enough work remains that the answer
  still matters when read. Never over an open menu, never from a status item
  macOS has hidden.
- **Render the readout on the side where the bytes land or leave.**

---

## How resource trade-offs are ordered

When speed, RAM, disk, I/O, and CPU pull against each other, decide in this order:

1. **Capability first.** The paste must succeed at any size a native paste would (§1). A choice
   that can fail on a large payload loses to one that cannot.
2. **Match-or-beat native on Kernova's *own* marginal overhead.** Judge by the CPU/RAM/disk/I/O
   Kernova *adds*, balancing all of them — not by the system-wide cost of the operation the user
   chose. Prefer the option whose **peak cost stays bounded as payload size grows**.
3. **Then UX.** Non-instant transfers must be legible and non-blocking (§13), and abortable
   immediately (§9).
4. **Reach for complexity when it wins on 1–3** (§12).

---

## Engineering practices

Non-negotiable mechanics for how clipboard changes ship:

- **Owner logic exists once.** Offer, request, pull, gate, refusal and abort behavior for both
  roles and both channels lives in KernovaKit's `ClipboardEndpoint`; a rule needed on one side is
  added there and applies to both. Host and guest code are adapters: what to snapshot, when to
  publish, and where to render.
- **Verify at the seam.** Protocol and stream changes get deterministic, transport-level tests
  (socketpair round-trips through the real sender and receiver) covering inline and file paths,
  a stalled peer, abort, and digest/size mismatch. Use event-driven waits, never sleeps.
- **Gate protocol changes on capability, not on version.** Protocol changes are gated by the Hello
  exchange's `capabilities` list; frames carrying an unsupported `Frame.protocol_version` are
  dropped silently. That list says which features a peer speaks, never which agent build it is —
  what a change may assume about the agent on the other end is AGENTS.md's current-only rule.
