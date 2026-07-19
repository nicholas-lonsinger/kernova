# CLIPBOARD.md

Guiding principles for host↔guest clipboard sharing in Kernova.

> This document is **authoritative** for the clipboard subsystem. Consult it before
> designing, extending, or refactoring any clipboard code — and before picking up any
> clipboard issue. Where it conflicts with intuition or with an existing implementation,
> this document wins and the implementation is the thing to change. Structural facts
> (types, data flow, test coverage) live in [ARCHITECTURE.md](ARCHITECTURE.md); product and
> UI philosophy live in [SPEC.md](SPEC.md). This file is the *why* and the *rules*.

## Scope

- **In scope:** macOS host ↔ **macOS guest** clipboard sharing over the vsock streaming
  transport (`VsockClipboardService` / `VsockGuestClipboardAgent` and the `KernovaKit`
  stream engine).
- **Out of scope (for now):** Linux guests (the separate text-only SPICE path) and Windows
  guests. Size and behavior targets for other guests are **to be determined later** and must
  not constrain the macOS↔macOS design.
- **The reference target is native macOS.** The yardstick for every decision is: *what would
  this copy/paste do if both ends were the same Mac?* We match that on capability and aim to
  match or beat it on resource cost. For the *cross-boundary behavior* — host and guest are two
  separate machines — the closest model is Apple's own **Universal Clipboard** between two
  devices: advertise lightweight **metadata** on copy, then transfer the bytes **on demand at
  paste** — asynchronously, with progress, and with no blocking deadline. Never an eager
  broadcast of the content, never a synchronous blocking pull. §2 (File Provider for files) and
  §3 (pay on consume) are how we match that; the synchronous pasteboard provider is reserved for
  inline content that comfortably fits the OS paste deadline (plus the size-capped file fallback
  when the File Provider toggle is off — see §2's honest caveats).
  - **"On demand at paste" is not a platform guarantee — it is ours to build.** The guest's OS
    continuity-pasteboard advertiser (`useractivityd`, via pboard's remote layer) fetches the
    promised `public.file-url` flavor from the publishing provider on **every new pasteboard
    generation**, independent of paste and independent of Apple Account state — observed live on
    a guest with no Apple Account signed in, `useractivityd`/`sharingd`/`rapportd` all running
    (#542 ground-truth). This advertiser is account-independent OS infrastructure, distinct from
    Universal Clipboard the feature; this section's reference model must not be read as implying
    the fetch only happens when Universal Clipboard is configured. See §3's caveat for the
    consequence for representations whose fulfillment materializes bytes — and for the
    neutralization: a `.currentHostOnly` write is never processed by the advertiser (#542).

---

## North star

**Our job is to facilitate the copy/paste — nothing more, nothing less.** The user decided to
copy this content; we move it across the boundary with the least possible Kernova-added
overhead and the most native-feeling experience. We do not editorialize, we do not protect the
user from a large transfer they chose to perform, and we do not impose limits macOS itself
would not.

Everything below is a consequence of that sentence.

---

## Principles

### 1. No Kernova-imposed size bound

**If a copy/paste works natively on macOS, it must work host↔guest through Kernova — at any
size, for every representation.** macOS does not cap pasteboard content (it is bounded only by
memory and swap); therefore Kernova must not either.

- Any fixed ceiling in the transport (e.g. the former 256 MiB inline cap, since dissolved into a `maxResidentInlineBytes` residency spill threshold) is a Kernova
  artifact, not a macOS limit, and **must be treated as a defect to dissolve**, not a feature
  to preserve.
- **Residency is an implementation detail, never a reason to cap.** Whether a representation's
  bytes live in RAM, on disk, or in a memory-mapped file is our choice; it must not change
  *whether the paste succeeds*. The inline-vs-file distinction describes the **pasteboard
  flavor the destination receives**, not where the bytes sit. A large "inline" representation
  must be backed by streamed/mmapped storage so there is nothing left to cap.
- The **only** thing that may be bounded is what the **clipboard window renders** (see §5),
  because that is a small panel, not the data path.

### 2. Disk staging is a fallback, not the default

**Match macOS's own residency.** If a native copy/paste of this content would not touch disk,
prefer a path that does not either. Disk is one tool, reached for only when the destination is
genuinely a file or the payload cannot responsibly stay in RAM — never as a reflexive
intermediate copy.

Preferred mechanisms, in order:

1. **On-demand materialization (File Provider / "Cloud Files").** Present the inbound content
   as a placeholder that returns from paste *instantly*; let the receiving OS demand the bytes
   when the app reads them, and write them **once, directly to the system-provided destination
   URL**, on a background thread, with native progress and no deadline. This is the mechanism
   for the file-destination case.
2. **Direct streaming into the served representation.** When the destination demands an inline
   type, stream bytes straight into the data handed to the pasteboard — RAM-resident, exactly
   like native — rather than through a disk round-trip.
3. **Bounded disk/mmap fallback.** Only when neither of the above is viable (notably very large
   *inline* data that would otherwise risk the OS paste deadline) may we stage to disk and serve
   via a memory-mapped read.

**A serialized container (a directory archive) is no exception.** Moving a directory requires
serializing the tree (§6 fidelity, §11 AppleArchive), but the serialization must *itself* stream —
source-tree → archive bytes → wire → extracted destination-tree — with **no full-size archive ever
landing whole on disk** at either end, and never the extracted tree left coexisting with its own
archive. A folder archived eagerly at copy (a standing duplicate of the source) and a received `.aar`
staged in full before extraction are both the "reflexive intermediate copy" forbidden above; at worst
they stack a complete copy of the payload on *both* sides on top of the destination write. **Kernova's
own on-disk footprint for any transfer must approach zero beyond the destination file** — an
intermediate that scales with payload size is a defect to dissolve, not a shortcut to keep (the §12
"smarter software earns its keep" case). Integrity (§7) is kept by hashing **inline** as bytes stream,
not by materializing the whole archive to hash it.

Honest caveats this principle does **not** waive:

- A **file paste must produce a real file at the destination.** That write is disk — but native
  does it too, so it is "match native," not gratuitous. What we eliminate is the
  *Kernova-specific intermediate stage*, not the destination file.
- The **synchronous pasteboard provider API blocks and has no "still working" signal.** A large
  direct-to-RAM inline pull therefore risks the OS paste deadline with a beachball. This is
  precisely why File Provider (async, native progress, no deadline) is the mechanism for files,
  and direct-to-RAM is reserved for inline content that comfortably fits the deadline.
- The **File Provider ships behind an OS enablement toggle that defaults off.** macOS gates
  every File Provider domain behind an off-by-default System Settings switch. With it off, a
  file "Copy to Mac" (guest→host) falls back to the synchronous provider, capped at
  `ClipboardStreamTuning.maxDeadlineSafeFileBytes` (256 MiB) — applied to the **total** of the
  offer's sync-bound plain-file reps, all-or-nothing: one paste is one deadline-bound operation
  (the OS clock sees the sum, not each file), so a plain-file set that together exceeds the cap
  is refused whole with an enable-File-Provider affordance rather than beachballing into the
  deadline, while under the cap every plain-file rep pastes as its own capped synchronous item.
  Routing is decided per rep at *paste* time (§3): each eligible plain-file rep tries the File
  Provider first (no cap, no deadline once enabled) and falls back to this capped sync pull, so
  the cap exists only on the toggle-off path and vanishes entirely once the File Provider is
  enabled — `fetchContents` has no deadline and no size limit. A copy-click advisory surfaces
  the over-total refusal in the clipboard window immediately when the toggle is already known
  off, so the user isn't left with a silent paste failure. That residual cap is
  **accepted-under-constraint**, not a §1 defect: it is deadline-derived (the OS paste clock,
  not Kernova, bounds the fallback). With the `clipboard.dirtree.v1` capability negotiated (§6,
  #422) a copied directory is lazy-eligible on both directions and routes through the File
  Provider as a placeholder tree when the toggle is on; only when the capability is absent (an
  old peer) or the toggle is off does a directory fall back to the size-capped sync path, where
  it counts toward the total by its stat-walk estimate and the producer archives it at request
  time (never at copy). Without the capability, a copied directory on the host is pulled eagerly
  at "Copy to Mac" click (the pre-D1b-folders behavior), never through a deadline-bound callback.
- The **mirror-image host→guest path carries the same total cap** (#561), symmetric with
  "Copy to Mac": the guest's synchronous pull refuses the whole non-inline set (files **and**
  directories, minus any File-Provider-routed reps) when it totals over
  `maxDeadlineSafeFileBytes`, reporting one `clipboard.paste.too.large` back to the host rather
  than delivering a piecemeal subset. A directory counts toward the guest's total only when it
  is *not* File-Provider-routed: with `clipboard.dirtree.v1` negotiated and the toggle on, a
  folder paste routes through the guest File Provider as a placeholder tree (no deadline, no
  cap) exactly like a plain file; without the capability, or with the toggle off, the folder
  rides this synchronous path (counting toward the total by its estimate, extracting the
  request-time-built archive). The two directions are now symmetric on folders. Both suppress the
  offer-time advertiser fetch that once made an uncapped pull fire with no paste at all — each
  side's promise write is `.currentHostOnly` (§3, #542/#408) — so the sync-promise pull runs
  only on a real paste, and the cap guards that real paste.

### 3. Pay on consume (laziness is the rule)

**Never read, hash, copy, archive, or materialize a payload until something actually consumes it.**
Inbound content is published as a metadata-only placeholder; bytes are pulled only when a
destination pastes that representation, or when the window must render a preview (a separate,
bounded pull — see §5).

- **Routing is also pay-on-consume (#427 leading edge).** The guest decides
  File-Provider-vs-synchronous per file rep at *paste* time, inside the unified `.fileURL`
  provider closure — a plain-file item's shape (`[.fileURL]`) is identical on both routes, so
  nothing forces the decision earlier. The dataless placeholder is therefore created on the
  first real paste fire, not at offer time: the "Kernova Clipboard" folder stays empty until
  something consumes the offer, and an offer that arrives while the domain isn't ready simply
  routes lazily on its next paste (the re-check that replaced the #429 availability-flip
  re-publish). The placeholder's *removal* stays supersession-scoped (next offer/release) by
  deliberate decision: the pasted copy is an APFS clone of the domain copy, so post-paste
  eviction reclaims no physical disk, and removing the dirent would dangle the pasteboard's
  cached URL (a fulfilled provider never re-fires), breaking second pastes and drag-out.
  Conscious trade: the folder can't be browsed *before* a paste — ⌘V is the flow, and the
  surface is transient by design.

- No surface may eagerly read a full payload "to be ready." Cost that is paid for bytes the user
  never pastes is forbidden.
- **Honest caveat: "pulled only on paste" assumes every published flavor is cheap to produce.**
  On every new pasteboard generation, the guest's OS continuity-pasteboard advertiser fetches the
  promised `public.file-url` flavor from the publishing provider — with no user paste (Scope's
  Universal Clipboard note, #542 ground-truth). A dataless File Provider placeholder URL and
  inline concrete values satisfy that fetch for free; a **sync-path file promise does not** —
  its fulfillment runs the full pull (`pullRepresentation`), so the advertiser's offer-time fetch
  materializes the entire file with no paste ever issued. The rule this establishes: a published
  representation is only genuinely lazy if **every** flavor it exposes is cheap to produce at
  registration time, not merely at the moment we intend it to be consumed. This bit hardest
  on the host→guest sync-promise fallback — an uncapped pull (until #561 added the mirror-image
  size cap, §2) that the advertiser also made paste-independent, until #542 scoped the
  guest's promise write `.currentHostOnly`: the advertiser then never processes the generation
  at all (no item-to-advertise determination, no flavor fetch — verified live: a 1.5 GiB
  toggle-off offer sat 160 s with zero bytes pulled, and a real paste still streamed
  immediately). The rule above still governs any surface that publishes an **unscoped**
  promise; host-only scoping is the escape hatch when a flavor cannot be cheap.
- This applies in **both directions**, including host "Copy to Mac": the host pasteboard write
  is lazy (a provider), and since #559 its File-Provider-vs-synchronous routing and placeholder
  creation are likewise paste-scoped — decided inside the provider closure on the first real
  paste (the #427 leading edge, host mirror), not at the moment the button is clicked. The one
  host-side exception is a copy-click advisory that refuses an over-total plain-file set up
  front when the File Provider toggle is already known off (§2), so the user gets the message
  in the window instead of a silent paste failure.
- **Serializing a directory into an archive is materialization.** Building a folder's `.aar` at
  copy time — a standing, full-size on-disk duplicate of the source paid before any paste — is the
  forbidden eager case, not an exception to it. With `clipboard.dirtree.v1` negotiated (§6, #422)
  no archive is built at all: the producer retains the *source* folder and walks it on demand
  (a listing, then per-child streams), so a folder paste pays for exactly the child files the
  consumer materializes. Only the capability-absent / toggle-off fallback still archives, and it
  is deferred to **request** time (never copy time) and bounded by the deadline-safe cap (§2).

### 4. One data plane; gating is a checkpoint, not a fork

**Gated (clipboard window) and passthrough modes must share a single data path.** They differ
only in *when consume is triggered* — gating inserts an explicit-intent approval step in the
middle — never in *how bytes move*. There must be no second, parallel transport for passthrough.

- The system is built to support both modes from one mechanism. Adding passthrough must not add
  a divergent code path; it changes *who/what* authorizes the pull, not the pull itself.
- The gate's purpose is **trust** (§10), not transformation. It is the boundary that stops a
  guest from reading the host clipboard without explicit user intent.
- **Realized by `ClipboardPassthroughCoordinator`** (per VM, host-side only): a 0.5 s host-pasteboard
  poll drives the outbound `ClipboardPasteboardIntake` → `grabIfChanged()` choke-point, and a new-offer
  observation drives the shared `HostClipboardPublisher.publish` — the same two choke-points the window
  gestures use. Enabling requires explicit confirmation; the toggle (`clipboardPassthroughEnabled`)
  is hot-toggleable. When several VMs run with passthrough on, the host pasteboard is genuinely shared
  across them (a sibling's inbound write becomes another's outbound forward); this terminates rather
  than loops because each guest agent suppresses its own echo. Enabling passthrough does **not** waive
  §3 for the guest→host direction — the auto-publish reuses the same lazy promise write, so bytes are
  still pulled on paste; it does mean an inline rep (text, small image) is materialized once per guest
  copy, exactly as an explicit "Copy to Mac" would.

### 5. The window is a preview; the preview is never on the data path

**The clipboard window renders a bounded, cheap preview and nothing more.** The preview decision
must never influence the bytes that pass through — the content delivered to the destination is
identical with or without gating.

- A preview must be derivable **cheaply**: header-only metadata, a size-capped thumbnail decode
  (no whole-file load), or a placeholder for anything too large to render cheaply. It must never
  require the full payload resident.
- The preview *may* trigger a **bounded** preview-pull (capped, renderable representations only)
  so the window can show a thumbnail. That pull is an optimization for one small panel; it is
  capped and must never escalate into a full materialization.
- A concealed (password) snapshot is never rendered at all — only its presence is shown.

### 6. Fidelity: preserve every representation, resolve at paste time

**Clipboard content is a set of representations (text, RTF, image, file URL, …), not one blob.**
Preserve **every** representation the source offered, and choose which to hand over at the moment
the destination asks — not earlier.

- Dropping a representation the source provided (e.g. losing an inline image when syncing rich
  text) is a fidelity defect.
- Round-trip equality is the bar: content copied on one side and pasted on the other must be
  indistinguishable from a native copy/paste, across every flavor the destination might request.
- **Directory fidelity rides File Provider item metadata, not AppleArchive** (folder D1b,
  `clipboard.dirtree.v1`, #422). A folder placeholder tree carries per-node fidelity in its
  `ClipboardTreeListing` (each node's kind/size/perms/mtime, plus the root folder's own mtime via
  `root_mtime_ms` — without it the pasted folder lands with an epoch date) and reconstructs it on
  the `NSFileProviderItem`: symlinks via `symlinkTargetPath` + `UTType.symbolicLink` (recorded,
  never followed), the executable bit via `fileSystemFlags` (the FP item surface carries **user**
  read/write/execute only — group/other permission bits do not cross on this path), empty
  directories as enumerable containers, and modification dates via `contentModificationDate`.
  **OS packages (.app/.rtfd) are served as plain `.folder` containers in the domain** — a
  package-conforming `contentType` makes the system fetch the container as one atomic file
  (observed live as Finder error -36) instead of enumerating its children; the pasted copy still
  opens as a package because LaunchServices derives packageness of an on-disk directory from its
  extension/bundle bit (the `.app`-signature acid test: a bundle's code signature lives in
  ordinary files — the Mach-O and `_CodeSignature/` — which a faithful per-child copy preserves).
  **Known gap:** extended attributes (`xattr`) are **not** carried
  through the File Provider item surface today (`NSFileProviderItem.extendedAttributes` governs
  the domain's own sync, and whether it materializes onto a pasted-out copy is unverified). A
  file's data, structure, permissions, and mtime cross faithfully; xattrs (e.g.
  `com.apple.quarantine`, Finder tags) do not. Tracked as a follow-up (#603) — verify live before
  relying on xattr round-trip. The destination side can also *add* metadata: Finder stamps
  `com.apple.FinderInfo` on bundle-named directories (.app/.appex/.bundle) it creates during the
  copy, which `codesign --verify --strict` reports as detritus on an otherwise byte-identical
  bundle (verified live: the pasted bundle passes strict verification after `xattr -cr`; a plain
  `cp -R` of a sealed system app shows the same class of divergence). The capability-absent / toggle-off archive fallback preserves the
  full canonical key set (including xattrs) via AppleArchive, so it is the higher-fidelity path
  when xattrs matter.

### 7. Integrity is not negotiable for speed

The vsock transport has **no CRC**; the end-to-end SHA-256 verification is the *only* corruption
detector. **It stays.**

- Optimize by removing **redundant** work — re-hashing bytes already hashed, hashing resident
  bytes a second time — **never** by removing the *only* correctness check.
- Echo suppression and dedup are digest-based and must remain correct under concurrency. A
  performance change that weakens a correctness or integrity guard is rejected by default,
  regardless of the speed it buys.

### 8. Keep the latency-sensitive thread free

The host main actor and the guest run loop are latency-sensitive. **They must never block on
work that scales with payload size** — hashing, copying, archiving, or disk I/O.

- Payload-proportional work runs off-actor / off the run loop. Hashing the editor buffer on every
  keystroke, or reading a full payload synchronously on the main actor, is a defect.
- This is the clipboard application of the project's `@MainActor` concurrency model: VZ- and
  pasteboard-touching state stays on the main actor; heavy bytes do not.

### 9. Abort and restart must be immediate, idempotent, and bidirectional

**Cancellation must be fast and clean in both directions.** A dropped, superseded, or failed
transfer must wake any parked pull **immediately** — never leave it stalling until a backstop
timeout.

- Aborts propagate both ways (host→guest and guest→host) and resolve **idempotently**; a late
  duplicate abort is harmless.
- Restart after abort must be cheap: no orphaned state, no leaked staging, no half-open channel.
- Backstop timeouts are a last resort, not the primary cancellation path.

### 10. Trust boundary and privacy

**The guest is untrusted.** The host must not expose its clipboard to a guest absent the sharing
toggle and (in gated mode) explicit user intent.

- Gating (§4) is the explicit-intent boundary; it exists so the guest cannot silently read the
  host clipboard.
- **Honor pasteboard privacy markers.** Transient / auto-generated snapshots
  (`org.nspasteboard.*`) are not synced. Concealed (password) content may sync but its bytes
  must never reach a view — only its presence is shown (§5).
- **Guest→host writes never leave the host.** `HostClipboardPublisher` marks every "Copy to Mac"
  pasteboard write `.currentHostOnly`, unconditionally — guest content becomes host-owned data on
  arrival and must not be re-advertised to the user's other Apple-Account-linked devices over
  Universal Clipboard (#560).
- **Host→guest promise writes are host-only too.** The guest agent prepares every inbound
  promise write with `.currentHostOnly` — primarily so the continuity-pasteboard advertiser
  never fetches the promised flavors at offer time (§3, #542), and equally so host-originated
  content is not re-advertised off the guest.
- Before non-trusted guest workloads are supported, the vsock listener must authenticate per VM.

### 11. Sandbox-forward by construction

Kernova targets eventual Mac App Store distribution. **New clipboard code must be written to be
sandbox-safe from the start** — never reworked toward it later.

- Use **in-process Apple framework APIs**: AppleArchive (not `ditto`/`tar`/`zip`), File Provider
  (not bespoke shelling), `Data`/`FileHandle` over `Process`/`NSTask`.
- Do not introduce entitlements unavailable to Mac App Store apps, and do not bake in assumptions
  that a sandboxed extension could not satisfy (e.g. a sandboxed File Provider extension cannot
  open a vsock directly — relay through the agent).

### 12. Complexity is an acceptable price for a measurable win

When a simpler implementation and a more sophisticated one differ on a **real metric** — disk,
memory, I/O, CPU, or UX (progress, speed, non-blocking) — **take the sophisticated one.** More
code is acceptable when it materially improves the actual effect on resources or experience.

- The guard is **"measurable."** Complexity that does not move a real metric is just complexity,
  and is rejected.
- This is what licenses the harder mechanisms above (File Provider, direct-stream, mmap,
  off-actor pipelines) over the expedient disk round-trip.

---

## How resource trade-offs are ordered

When speed, RAM, disk, I/O, and CPU pull against each other, decide in this order:

1. **Capability first.** The paste must succeed at any size a native paste would (§1). A choice
   that can fail on a large payload loses to one that cannot.
2. **Match-or-beat native on Kernova's *own* marginal overhead.** Judge by the CPU/RAM/disk/I/O
   Kernova *adds*, balancing all of them — not by the system-wide cost of the operation the user
   chose. Prefer the option whose **peak cost stays bounded as payload size grows** (streaming,
   mmap, on-demand) over a faster one whose peak scales linearly.
3. **Then UX.** Non-instant transfers must be legible and non-blocking (§13), and abortable
   immediately (§9).
4. **Reach for complexity when it wins on 1–3** (§12).

---

## 13. Making slow work legible — and designing around OS deadlines

Large transfers are streamed and take real time. Two obligations follow:

- **Surface progress** for any non-instant transfer, in both directions, driven off the
  transport's existing byte-level progress. Terminal states (completion, error, abort) must clear
  the indicator — never leave a stuck bar.
- **Progress UI is necessary but not sufficient.** Some host-OS deadlines cannot be signaled into
  — the synchronous pasteboard provider has no keepalive, and the receiving OS will abandon a
  promise on its own clock. For unbounded operations, **prefer an API with no host-OS deadline**
  (File Provider) over one where we must beat a clock we do not control.

The File Provider paste path is now **determinate end to end** (#426), in both directions. The
extension can't see the vsock transfer, so the owner pushes the receiver's per-chunk
`(bytesTransferred, totalBytes)` back to the sandboxed extension over the *existing* servicing XPC
connection — a one-way `FileProviderControl.fetchProgressed`, coalesced to ~1% of the total or
~100 ms apart (always the final chunk) so a multi-GB pull can't flood the pipe — which drives a
byte-denominated `fetchContents` `Progress` (`kind = .file`, `fileOperationKind = .downloading`),
so Finder renders a real download bar instead of the pulsing indeterminate one. A version-skewed
peer without the selector drops the push and degrades to no-progress without tearing down the
connection. The host clipboard window's in-app bar records the guest→host pull from the same
per-chunk callback (`performBlockingPull`, direction `.inbound`); both indicators clear at every
terminal. No vsock wire change — the channel is the servicing XPC, not the transport.

---

## Engineering practices

These are not negotiable mechanics for *how* clipboard changes ship:

- **Verify at the seam.** Protocol and stream changes get deterministic, transport-level tests
  (socketpair round-trips through the real sender/receiver), covering both inline and file paths,
  backpressure, abort, and digest/size mismatch. Off-actor concurrency guards get deterministic
  tests. Use **event-driven waits**, never timing-based sleeps, to avoid CI flakes.
- **Evolve by capability negotiation, not legacy shims.** Protocol changes are gated by the Hello
  exchange's `capabilities` list; frames carrying an unsupported `Frame.protocol_version` are
  silently dropped (no error frame is sent). The other Hello version fields are advertised but
  gate nothing today — `service_version` is diagnostic-only and `bundled_agent_version` just
  drives the guest's update prompt; `version.unsupported` is a machine-readable error code the
  proto reserves as an example, but no path constructs it yet.
  There is **no legacy fallback**. Any behavior change that requires a guest reinstall **bumps
  the guest agent version**. Greenfield — do not add back-compat decode paths for data that does
  not exist.
- **Log at the right level.** Lifecycle transitions (transfer started/completed/aborted) at
  `.notice`; recoverable degradations at `.warning`; failures at `.error`. No `print`/`NSLog`.
  When capturing, filter `subsystem BEGINSWITH "app.kernova"` — the agent and the File Provider
  extensions log under their own subsystems (see AGENTS.md's Logging table), and an exact match
  on `app.kernova` yields a misleadingly complete-looking partial capture.
- **A reinstalled guest agent does not replace its running File Provider extension.**
  `fileproviderd` keeps the already-spawned extension process (the old binary) serving the domain
  across an agent reinstall + relaunch. When live-testing an extension change, kill it
  (`pkill -f KernovaMacOSAgentFileProvider`; `fileproviderd` respawns the new binary on demand) —
  or reboot the guest — before attributing File Provider behavior to the new build (observed in
  #604's verification: a fixed extension appeared to still fail until the stale process was
  killed).

---

## Issue → principle triage map

Use this when picking up a clipboard issue: the governing principle(s) dictate the shape of the
fix, not just whether to fix it. (macOS-guest issues only; Linux/Windows out of scope.)

| Issue | Governing principle(s) | What the principles dictate |
|-------|------------------------|------------------------------|
| **#370** — image files > 256 MiB can't paste (force-inlined, rejected by `maxInlineBytes`) | §1 No size bound, §2 Disk-as-fallback | There is no legitimate cap. The fix is not "fall back to file-only over the cap" — it is to make inline reps disk/mmap-backed so the inline image bytes are uncapped too. **Folds into #393.** ✓ **Resolved** — the receiver spills a large inline rep to disk and serves it back via mmap. |
| **#393** — mmap staged files when materializing inline pasteboard bytes | §1, §2, §8 | mmap is the mechanism that makes inline residency an implementation detail (§1), keeps Kernova's added RAM near zero (§2/ordering), and keeps the main thread off payload-sized reads (§8). Doing this **dissolves the §1 cap** and resolves #370. ✓ **Resolved** — `maxInlineBytes` is now `maxResidentInlineBytes`, a residency spill threshold. |
| **#392** — make host "Copy to Mac" write the pasteboard lazily | §3 Pay on consume | The one place inbound content is still eager. Convert to a provider so bytes are read only when the destination pastes — in both directions, laziness is the rule. ✓ **Resolved** — the host pasteboard write is a lazy provider (#408); every plain-file rep is routed through a host File Provider placeholder at paste time (#434 single-file, #559 multi-file). |
| **#394** — inline payloads SHA-256'd redundantly and on the main thread | §8 Keep the thread free, §7 Integrity | Remove the **redundant** hashes and move the unavoidable one off the main actor (§8). Do **not** drop the end-to-end verify hash (§7) — redundant work goes, the only integrity check stays. ✓ **Resolved** — editor hashing moved off the main actor on a debounce (#413). |
| **#377** — throughput is software-bound; validate on real vsock, then cut per-chunk overhead | Ordering (marginal overhead), Engineering practices | Capability is already met; this is pure §-ordering step 2. **Measure on real vsock first** (verify at the seam), then cut the avoidable per-chunk copy. Never ship a chunk-size bump without co-scaling the window. |
| **#376** — File Provider domain for large-file paste (no 60 s deadline) | §2 Disk-as-fallback (on-demand), §13 OS deadlines, §11 Sandbox-forward | This is the canonical §2 mechanism: instant placeholder, on-demand `fetchContents`, write once at the destination, native progress, no deadline. Also killed #371's 2×-disk. Extension can't open vsock — relay through the agent (§11). **Partially shipped** — D1a (guest transport) landed in #425; the host-side "Copy to Mac" mirror (D2) is the separate issue #424, shipped in #434; D1b multi-file landed with the unified paste-time routing (§3's routing bullet — every eligible plain-file rep in an offer routes, not just a single one), and the host "Copy to Mac" mirror of that reshape landed in #559. Folders now cross via the placeholder-tree design too (D1b folders, negotiated `clipboard.dirtree.v1`, #422) — a directory rep pastes as a placeholder tree with per-child fetch on both directions, with the eager-archive path kept only as the capability-absent / toggle-off fallback (archived at request time). Progress (#426) landed. |
| **#422** — a directory crosses as a fully materialized archive, staged whole on **both** sides (≈3N peak disk) | §2 (no reflexive intermediate copy), §3 (pay on consume), ordering (bounded peak), §12 (smarter wins) | ✓ **Resolved** — the folder placeholder-tree design (D1b folders, negotiated `clipboard.dirtree.v1`): a copied folder crosses as a File Provider placeholder *tree* — the producer retains the **source** folder and walks it on demand (a listing, then each child file over the SHA-verified stream), so **no archive is built at copy time on either side** and Kernova's own disk for the transfer approaches zero beyond the destination. The offer carries a stat-walk size *estimate* instead of the archive's exact byteCount+SHA. The toggle-off (or capability-absent) fallback keeps the capped archive path but archives at **request** time, not copy time; its intermediate is bounded because the deadline-safe total gate refuses a sync-bound directory set over `maxDeadlineSafeFileBytes` (§2) — that ≤`maxDeadlineSafeFileBytes` bound on the only path that still archives is what lets this close. Fidelity moved from AppleArchive to FP item metadata (§6). |
| **#354** — clipboard transfer progress UI (bar + ring) | §13 Legibility, §9 bidirectional, §5 preview-only | Drive both indicators off existing transport progress, both directions; clear on terminal states. Progress is a window affordance — it must not touch the data path (§5). ✓ **Resolved** — progress bar + ring driven off transport progress (#417). |
| **#82** — opt-in automatic clipboard passthrough | §4 One data plane | Passthrough is the gate-less mode of the **same** path — a change to *when consume is authorized*, not a parallel transport. ✓ **Resolved** — `ClipboardPassthroughCoordinator` (per VM, host-side only, no proto/`PolicyUpdate` change) polls the host pasteboard and funnels changes through the identical `ClipboardPasteboardIntake` → `grabIfChanged()` choke-point the window's Paste uses, and auto-invokes the shared `HostClipboardPublisher.publish` (the same lazy write "Copy to Mac" uses) on each new inbound offer. Marker filtering (§10) is inherited from the shared intake; echo is suppressed by the publisher's post-write `changeCount` (a digest can't be the key — inbound writes are lazy promises). Drives both transports; the `clipboardPassthroughEnabled` toggle requires explicit confirmation to enable and is hot-toggleable. |
| **#145** — per-VM auth on the vsock listener | §10 Trust boundary | Required before non-trusted guest workloads; the host must authenticate the guest per VM. |
| **#330** — preference to disable the guest-agent install prompt | §10 (consent/UX) | Peripheral to transport; a consent/UX affordance, not a data-path change. |
| **#499** — a stale cancel/abort for one pull attempt can land on a same-id retry instead | §9 idempotent/bidirectional abort | The `transfer_id`'s determinism from `(generation, repIndex, direction)` is load-bearing (cancel re-derives it; `cancelPull`'s race guard depends on it) — an id-format change to disambiguate attempts was rejected as disproportionate. ✓ **Resolved as documented-benign** — the residual (a spurious re-abort/retry, never corruption) is pinned by a regression test and the invariant is documented on `ClipboardTransferID` itself. |
| **#500** — a duplicate pull registration for the same id silently overwrites the prior one | §9 wake immediately, not a backstop stall | `LazyPullCoordinator.pull`/`ClipboardStreamReceiver.awaitTransfer` had no guard against a concurrent duplicate registration (e.g. a File Provider fetch retry after a dropped owner connection). ✓ **Resolved** — a duplicate registration supersedes the prior one, resolving it immediately via a distinct `.superseded` outcome (not `.cancelled`, which would let the displaced caller tear down the live successor's awaiter). |
| **#560** — Copy to Mac advertises guest clipboard content to other devices over Universal Clipboard | §10 Trust boundary | `HostClipboardPublisher` prepared every write with `clearContents()`, which leaves the pasteboard cross-device-advertisable. ✓ **Resolved** — every host write now prepares with `prepareForNewContents(with: .currentHostOnly)` instead, applied unconditionally at the single inbound-publication choke point (§4) on every write, since the option does not survive a later prepare/clear. |
| **#542** — guest pulls a host clipboard offer's full payload at offer time, with no paste (toggle-off sync path) | §3 Pay on consume, §10 Trust boundary | The guest's continuity-pasteboard advertiser fetched the promised `public.file-url` at offer time, and fulfilling it materialized the whole file (§3's advertiser caveat). ✓ **Resolved** — the guest's promise write prepares with `.currentHostOnly` (the #560 mechanism applied guest-side), which keeps the advertiser from processing the generation at all; verified live (1.5 GiB toggle-off offer idle 160 s with zero bytes moved, in-guest log shows no advertiser fetch, a real paste still streams immediately). |
| **#561** — host→guest paste has no deadline-safe size cap, unlike guest→host | §2 Disk-as-fallback (deadline cap), §13 OS deadlines | The two directions were asymmetric: the host's synchronous fallback already refused an over-cap file, but the guest's `pullRepresentation` checked only staging disk capacity. ✓ **Resolved** — the guest's synchronous pasteboard-provider pull refuses when the paste's sync-bound reps (non-inline, minus File-Provider-routed) **total** over `maxDeadlineSafeFileBytes`, all-or-nothing (one `clipboard.paste.too.large` per offer, surfaced in the host's clipboard window — no piecemeal subset); the File Provider relay (`fetchStagedFile`, no deadline) stays uncapped via a `deadlineBound` parameter on the shared `pullRepresentation`. The host "Copy to Mac" total gate is now symmetric (#559, `syncBoundTotalBytes`). One asymmetry remains: the guest has no File-Provider escape hatch for folders yet (D1b folders), so every inbound directory rep rides this same deadline-bound path today, while the host's directory pull is eager and never deadline-bound (so host directories don't count toward its total). |
| **#427** — File Provider placeholder scoped to the paste lifetime, not the offer | §3 Pay on consume, §2 (on-demand) | The placeholder existed for the whole offer lifetime — created the instant the host copied, lingering after a paste. ✓ **Resolved** — routing (and so placeholder creation) moved into the unified paste-time provider closure (§3's routing bullet): the folder stays empty until a real paste, and an offer that missed a ready domain re-checks on its next fire (deleting the #429 re-publish and #510 stale-pull refusal machinery). The trailing edge is deliberately supersession-scoped — post-paste eviction reclaims no physical disk (the pasted copy is an APFS clone) and dirent removal would dangle the pasteboard's cached URL, breaking second pastes and drag-out. The host side of this paste-scoping landed with #559. |
| **#559** — host "Copy to Mac" routes only a single plain-file rep lazily (D2 scope limit) | §2 Disk-as-fallback (deadline cap), §3 Pay on consume | The host mirror of D1b: dissolve the single-file gate so every eligible plain-file rep routes, and move routing into the paste-time provider closure. ✓ **Resolved** — `materializeForCopy` defers every lazy-eligible plain-file rep as a `.lazyFile`; the pasteboard closure (`copyToMacFileURL`) tries the File Provider first (publishing all eligible reps together, latched on success) and falls back to a size-capped sync pull gated by the offer's plain-file **total** (`syncBoundTotalBytes`), all-or-nothing, with a copy-click advisory when the toggle is already known off. Placeholder creation is now paste-scoped (#427 host mirror); `CopyToMacDropReason.multipleFiles` and its "Only one file…" message are removed. |
| **#426** — File Provider paste shows only an indeterminate "Preparing to copy…" bar, in both directions | §13 Legibility, §5 preview-only | Drive the native `fetchContents` `Progress` off the transport's existing byte-level progress, both directions; the extension can't see the vsock transfer, so carry it over the servicing XPC (never the data path — §5). ✓ **Resolved** — a one-way, coalesced `FileProviderControl.fetchProgressed(generation:repIndex:bytesTransferred:totalBytes:)` push from the owner (fed by the receiver's per-chunk callback via `FileProviderPullProvider.fetchStagedFile`'s new `onProgress`) drives a byte-denominated `fetchContents` `Progress` (`kind = .file`, `.downloading`), routed by an in-flight `(generation, repIndex)` registry in `FileProviderServiceSource` (a late push for a finished pull no-ops; a version-skewed peer lacking the selector degrades to no-progress without tearing down the connection). The host clipboard window's in-app bar records the guest→host FP pull from the same callback (`performBlockingPull` → `ClipboardTransferProgressTracker`, direction `.inbound`), cleared at every terminal. No vsock wire change (the ground-truth correction: the outbound in-app half already recorded via `handleRequest` — only the host receive side was the gap). |

---

## Using this document

When you pick up a clipboard issue or write new clipboard code, check the change against these
principles in order:

1. Does it match **native capability** at any size (§1), without a Kernova-imposed cap?
2. Does it avoid **gratuitous disk** and minimize Kernova's **own** marginal overhead (§2, ordering)?
3. Is it **lazy** — paying only for bytes actually consumed (§3)?
4. Does it keep **one data plane** for gated and passthrough (§4), with the preview off the data path (§5)?
5. Does it preserve **fidelity** (§6) and **integrity** (§7)?
6. Does it keep the **latency-sensitive thread free** (§8) and remain **abortable immediately** (§9)?
7. Is it within the **trust/privacy** boundary (§10) and **sandbox-forward** (§11)?
8. Where it adds complexity, does that complexity buy a **measurable** win (§12)?

If a principle here turns out to be wrong, fix the principle here first — then the code.
