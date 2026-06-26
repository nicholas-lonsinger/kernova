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
  inline content that comfortably fits the OS paste deadline.

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

Honest caveats this principle does **not** waive:

- A **file paste must produce a real file at the destination.** That write is disk — but native
  does it too, so it is "match native," not gratuitous. What we eliminate is the
  *Kernova-specific intermediate stage*, not the destination file.
- The **synchronous pasteboard provider API blocks and has no "still working" signal.** A large
  direct-to-RAM inline pull therefore risks the OS paste deadline with a beachball. This is
  precisely why File Provider (async, native progress, no deadline) is the mechanism for files,
  and direct-to-RAM is reserved for inline content that comfortably fits the deadline.

### 3. Pay on consume (laziness is the rule)

**Never read, hash, copy, or materialize a payload until something actually consumes it.**
Inbound content is published as a metadata-only placeholder; bytes are pulled only when a
destination pastes that representation, or when the window must render a preview (a separate,
bounded pull — see §5).

- No surface may eagerly read a full payload "to be ready." Cost that is paid for bytes the user
  never pastes is forbidden.
- This applies in **both directions**, including host "Copy to Mac": the host pasteboard write
  must be lazy (a provider), not an eager read at the moment the button is clicked.

### 4. One data plane; gating is a checkpoint, not a fork

**Gated (clipboard window) and passthrough modes must share a single data path.** They differ
only in *when consume is triggered* — gating inserts an explicit-intent approval step in the
middle — never in *how bytes move*. There must be no second, parallel transport for passthrough.

- The system is built to support both modes from one mechanism. Adding passthrough must not add
  a divergent code path; it changes *who/what* authorizes the pull, not the pull itself.
- The gate's purpose is **trust** (§10), not transformation. It is the boundary that stops a
  guest from reading the host clipboard without explicit user intent.

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

## Making slow work legible — and designing around OS deadlines

Large transfers are streamed and take real time. Two obligations follow (§13):

- **Surface progress** for any non-instant transfer, in both directions, driven off the
  transport's existing byte-level progress. Terminal states (completion, error, abort) must clear
  the indicator — never leave a stuck bar.
- **Progress UI is necessary but not sufficient.** Some host-OS deadlines cannot be signaled into
  — the synchronous pasteboard provider has no keepalive, and the receiving OS will abandon a
  promise on its own clock. For unbounded operations, **prefer an API with no host-OS deadline**
  (File Provider) over one where we must beat a clock we do not control.

---

## Engineering practices

These are not negotiable mechanics for *how* clipboard changes ship:

- **Verify at the seam.** Protocol and stream changes get deterministic, transport-level tests
  (socketpair round-trips through the real sender/receiver), covering both inline and file paths,
  backpressure, abort, and digest/size mismatch. Off-actor concurrency guards get deterministic
  tests. Use **event-driven waits**, never timing-based sleeps, to avoid CI flakes.
- **Evolve by capability negotiation, not legacy shims.** Protocol changes are gated by control-
  channel capabilities and `min_required_agent_version`; there is **no legacy fallback**. Any
  behavior change that requires a guest reinstall **bumps the guest agent version**. Greenfield —
  do not add back-compat decode paths for data that does not exist.
- **Log at the right level.** Lifecycle transitions (transfer started/completed/aborted) at
  `.notice`; recoverable degradations at `.warning`; failures at `.error`. No `print`/`NSLog`.

---

## Issue → principle triage map

Use this when picking up a clipboard issue: the governing principle(s) dictate the shape of the
fix, not just whether to fix it. (macOS-guest issues only; Linux/Windows out of scope.)

| Issue | Governing principle(s) | What the principles dictate |
|-------|------------------------|------------------------------|
| **#370** — image files > 256 MiB can't paste (force-inlined, rejected by `maxInlineBytes`) | §1 No size bound, §2 Disk-as-fallback | There is no legitimate cap. The fix is not "fall back to file-only over the cap" — it is to make inline reps disk/mmap-backed so the inline image bytes are uncapped too. **Folds into #393.** ✓ **Resolved** — the receiver spills a large inline rep to disk and serves it back via mmap. |
| **#393** — mmap staged files when materializing inline pasteboard bytes | §1, §2, §8 | mmap is the mechanism that makes inline residency an implementation detail (§1), keeps Kernova's added RAM near zero (§2/ordering), and keeps the main thread off payload-sized reads (§8). Doing this **dissolves the §1 cap** and resolves #370. ✓ **Resolved** — `maxInlineBytes` is now `maxResidentInlineBytes`, a residency spill threshold. |
| **#392** — make host "Copy to Mac" write the pasteboard lazily | §3 Pay on consume | The one place inbound content is still eager. Convert to a provider so bytes are read only when the destination pastes — in both directions, laziness is the rule. |
| **#394** — inline payloads SHA-256'd redundantly and on the main thread | §8 Keep the thread free, §7 Integrity | Remove the **redundant** hashes and move the unavoidable one off the main actor (§8). Do **not** drop the end-to-end verify hash (§7) — redundant work goes, the only integrity check stays. |
| **#377** — throughput is software-bound; validate on real vsock, then cut per-chunk overhead | Ordering (marginal overhead), Engineering practices | Capability is already met; this is pure §-ordering step 2. **Measure on real vsock first** (verify at the seam), then cut the avoidable per-chunk copy. Never ship a chunk-size bump without co-scaling the window. |
| **#376** — File Provider domain for large-file paste (no 60 s deadline) | §2 Disk-as-fallback (on-demand), §13 OS deadlines, §11 Sandbox-forward | This is the canonical §2 mechanism: instant placeholder, on-demand `fetchContents`, write once at the destination, native progress, no deadline. Also kills #371's 2×-disk. Extension can't open vsock — relay through the agent (§11). |
| **#354** — clipboard transfer progress UI (bar + ring) | §13 Legibility, §9 bidirectional, §5 preview-only | Drive both indicators off existing transport progress, both directions; clear on terminal states. Progress is a window affordance — it must not touch the data path (§5). |
| **#82** — opt-in automatic clipboard passthrough | §4 One data plane | Passthrough is the gate-less mode of the **same** path. Implement it as a change to *when consume is authorized*, not as a parallel transport. |
| **#145** — per-VM auth on the vsock listener | §10 Trust boundary | Required before non-trusted guest workloads; the host must authenticate the guest per VM. |
| **#330** — preference to disable the guest-agent install prompt | §10 (consent/UX) | Peripheral to transport; a consent/UX affordance, not a data-path change. |

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
