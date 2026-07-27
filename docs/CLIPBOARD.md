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
  devices — advertise metadata on copy, transfer the bytes on demand at paste, asynchronously and
  without a blocking deadline. Never an eager broadcast, never a synchronous blocking pull.

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

1. **On-demand materialization (File Provider)** for file destinations: return from paste
   *instantly* with a placeholder, then write the demanded bytes **once, directly to the
   system-provided destination URL**, off the latency-sensitive thread.
2. **Direct streaming into the served representation** for inline types, not a disk round-trip.
3. **Bounded disk/mmap fallback**, only when neither is viable — notably very large *inline* data
   that would otherwise risk the OS paste deadline.

**Kernova's own on-disk footprint for a transfer must approach zero beyond the destination file** —
which the destination write does not violate, since native pays it too. An intermediate that
scales with payload size is a defect to dissolve, and a serialized container is no exception:
serializing a tree (§6, §11) must *itself* stream, source tree → archive bytes → wire → extracted
destination tree, with no full-size archive landing whole on disk at either end and no extracted
tree left coexisting with its archive. Integrity (§7) is kept by hashing **inline** as bytes
stream.

Caveats this does **not** waive:

- The **synchronous pasteboard provider API blocks and has no "still working" signal**, so a large
  direct-to-RAM pull risks the OS paste deadline. Reserve it for inline content that comfortably
  fits.
- **macOS gates every File Provider domain behind an off-by-default System Settings switch**, so
  every File Provider design needs a deadline-bound toggle-off fallback. Cap it on the **total**
  of the offer's sync-bound representations, in both directions — the OS clock sees one paste as
  one operation, not each file — and **refuse an over-total set whole** rather than delivering a
  piecemeal subset, surfacing the refusal at copy time when the toggle is already known off. That
  cap is accepted-under-constraint, not a §1 defect, and it vanishes once the File Provider is
  enabled.
- **Keep the two directions symmetric.** A capability that makes a payload lazy-eligible one way
  must make it lazy-eligible the other.

### 3. Pay on consume (laziness is the rule)

**Never read, hash, copy, archive, or materialize a payload until something actually consumes it.**
Inbound content is published as a metadata-only placeholder; bytes are pulled only when a
destination pastes that representation, or for the window's bounded preview pull (§5).

- **Routing is pay-on-consume too**: which mechanism serves a representation is decided inside the
  provider closure on the first real paste, in both directions — not at offer time, not when a
  Copy button is clicked. A placeholder that exists before a paste was built too early.
- **A published representation is genuinely lazy only if *every* flavor it exposes is cheap to
  produce at registration time**, not merely when we intend it to be consumed — the OS fetches
  promised flavors on its own schedule (Scope). A dataless placeholder URL is cheap; a file
  promise whose fulfillment runs the full pull is not, and will materialize the whole payload with
  no paste issued. Where a flavor cannot be made cheap, scope the write `.currentHostOnly` (§10)
  so the advertiser never processes it.
- **Serializing a directory into an archive is materialization.** Retain the *source* folder and
  walk it on demand so a folder paste pays for exactly the children the consumer materializes.
  Only the fallback archives, deferred to **request** time and bounded by the cap (§2).
- **Do not evict a placeholder after its paste**; removal stays scoped to supersession. A
  fulfilled provider never re-fires, so removing the dirent dangles the pasteboard's cached URL
  and breaks second pastes and drag-out.

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
never escalate into a full materialization.

### 6. Fidelity: preserve every representation, resolve at paste time

**Clipboard content is a set of representations (text, RTF, image, file URL, …), not one blob.**
Preserve **every** representation the source offered and choose which to hand over at the moment
the destination asks. Dropping one — losing an inline image when syncing rich text — is a fidelity
defect; round-trip equality with a native copy/paste is the bar.

- **Directory fidelity rides File Provider item metadata, not the archive.** A placeholder tree
  carries each node's kind, size, permissions, and mtime — including the root folder's own, without
  which the pasted folder lands with an epoch date. Symlinks are recorded, never followed; empty
  directories are enumerable containers; only **user** read/write/execute bits cross.
- **Serve OS packages (`.app`, `.rtfd`) as plain folder containers.** A package-conforming
  `contentType` makes the system fetch the container as one atomic file instead of enumerating its
  children (observed live as Finder error -36, 2026-07-18). The pasted copy still opens as a
  package, and a bundle's code signature lives in ordinary files a per-child copy preserves.
- **Accepted gap: extended attributes cross on *no* paste path** — Finder tags,
  `com.apple.quarantine`, `kMDItemWhereFroms` — because every path streams content bytes into a
  freshly created destination file. Keep that uniform; one path carrying them alone would be a
  worse inconsistency than dropping them everywhere.
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
that scales with payload size** — hashing, copying, archiving, or disk I/O.

- Off-actor is the floor, not the ceiling: payload-proportional stages that gate the *protocol*
  need separating from each other too. A staging write sitting between a chunk's arrival and the
  ack that reopens the sender's credit window leaves the sender blocked on credit for most of a
  large transfer.
- Chunk size and the credit window are one tuning pair — never ship a chunk-size bump without
  co-scaling the window.

### 9. Abort and restart must be immediate, idempotent, and bidirectional

**A dropped, superseded, or failed transfer must wake any parked pull immediately** — never leave
it stalling until a backstop timeout, which is a last resort, not the cancellation path.

- Aborts propagate both ways and resolve **idempotently**; a late duplicate abort is harmless.
- **A transfer id stays derivable from `(generation, repIndex, direction)` alone.** Cancellation
  re-derives the id rather than remembering it, and the cancel race guard depends on that
  determinism — do not make the id format vary per attempt.
- Restart after abort must be cheap: no orphaned state, no leaked staging, no half-open channel.

### 10. Trust boundary and privacy

**The guest is untrusted.** The host must not expose its clipboard to a guest absent the sharing
toggle and (in gated mode) explicit user intent; gating (§4) is that explicit-intent boundary.

- **Honor pasteboard privacy markers.** Transient / auto-generated snapshots (`org.nspasteboard.*`)
  are not synced. Concealed (password) content may sync, but its bytes must never reach a view.
- **Every clipboard pasteboard write, on either side, is `.currentHostOnly`, unconditionally** —
  neither inbound guest content nor host-originated content may be re-advertised onward, and the
  scoping is also what stops the continuity advertiser fetching promised flavors at offer time
  (§3). Verified 2026-07-16: a 1.5 GiB toggle-off offer sat 160 s with zero bytes pulled, and a
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
it later. Beyond AGENTS.md's sandbox rules: archive with AppleArchive, never `ditto`/`tar`/`zip`,
and do not bake in assumptions a sandboxed extension could not satisfy — a sandboxed File Provider
extension cannot open a vsock directly, so relay through the agent.

### 12. Complexity is an acceptable price for a measurable win

When a simpler implementation and a more sophisticated one differ on a **real metric** — disk,
memory, I/O, CPU, or UX — **take the sophisticated one.** The guard is **"measurable"**:
complexity that does not move a real metric is just complexity, and is rejected.

### 13. Making slow work legible

**Surface progress for any non-instant transfer, in both directions.** Terminal states —
completion, error, abort — must clear the indicator; never leave a stuck bar. Progress UI is
necessary but not sufficient: a deadline we cannot signal into (§2) is not solved by showing a
bar, so for unbounded operations **prefer an API with no host-OS deadline**.

**Do not build progress for an OS-owned surface without first proving that surface consumes it.**
Finder's copy dialog does not: publication was log-proven full-duration in every live run, yet
every captured frame — all paste shapes, clean host boot included — showed the indeterminate
"Preparing to copy…" slide, never the byte-count "Copying…" presentation real consumption produces
(2026-07-22). Its sweep animation parks at the track's left edge each cycle, so a glance mimics a
determinate fill — classify from continuous capture, never sparse glances. The dialog also
dismisses itself tens of seconds into a multi-GB pull.

**Progress is aggregate per operation, never per file.** A session is one user-visible operation —
a paste, a Copy to Mac, a preview fetch, one side serving a peer's pulls — and its bar climbs
once, whether its transfers run sequentially or concurrently. One mechanism decides how much is
done, when an indicator may appear, and when it comes down; every surface renders the snapshot it
publishes.

- **Do not key a session by generation.** Inbound and outbound generations are independent counters
  that both start at 1, and a preview fetch's generation equals the paste manifest's, so any
  generation-keyed scheme merges unrelated operations. Key on a published manifest's denominators
  where one exists, otherwise an opaque token.
- **Evaluate the reveal delay on each event, not from a timer**, so an operation finishing inside
  the gate never flashes UI and one stalled before its first byte shows nothing rather than a
  frozen bar. **Linger briefly after the last transfer** so a long paste reads 100 % rather than
  vanishing at 99 %; cancelled and partial operations end the same way below 100 %, and
  supersession clears immediately.
- **Only a surface that interrupts gets a stricter bar.** A menu that opens itself takes over the
  screen: open it only for a paste, only once, only after the operation is worth interrupting for,
  and only while enough work remains that the answer still matters when read. Never over an open
  menu, never from a status item macOS has hidden.
- **Render the readout on the side where the bytes land or leave**, and **keep tracker instances
  per-scope** so two VMs measure independently — a pull reporting to the tracker it started under
  even after its VM is superseded, or that VM's paste vanishes mid-transfer.

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

- **Verify at the seam.** Protocol and stream changes get deterministic, transport-level tests
  (socketpair round-trips through the real sender and receiver) covering inline and file paths,
  backpressure, abort, and digest/size mismatch. Use event-driven waits, never sleeps.
- **Evolve by capability negotiation, not legacy shims.** Protocol changes are gated by the Hello
  exchange's `capabilities` list; frames carrying an unsupported `Frame.protocol_version` are
  dropped silently. There is **no legacy fallback**, and any behavior change requiring a guest
  reinstall **bumps the guest agent version**. Do not add back-compat decode paths for data that
  does not exist.
- **Filter log captures with `subsystem BEGINSWITH "app.kernova"`.** The agent and both File
  Provider extensions log under their own subsystems (AGENTS.md's Logging table), so an exact
  match yields a misleadingly complete-looking partial capture.
- **A reinstalled guest agent does not replace its running File Provider extension.**
  `fileproviderd` keeps the already-spawned extension process serving the domain across a
  reinstall and relaunch. The install and uninstall scripts kill it; when replacing the bundle any
  other way (Xcode build, manual copy), kill it yourself or reboot the guest before attributing
  File Provider behavior to the new build (observed 2026-07-18: a fixed extension appeared to
  still fail until the stale process was killed).
