# Post-#714 transfer pipeline: baseline, profile, and levers

**Date:** 2026-08-14 · **Hardware:** M1 Max, 32 GB, macOS 27.0 host · **Guest:** macOS 26.6.1, 4 vCPU / 8 GB, agent 0.62.0 · **Tracking issue:** #851

## Summary

First measurement pass over the unified lazy-always engine (#714) plus the #298
drop path. Payloads are `/dev/urandom` (incompressible by construction) unless
noted; rates are whole-transfer wall clock from the host log or the receiver's
`ClipboardTransferMetrics` line.

| Path (host app standalone) | Debug | Release |
|---|---|---|
| Drop file 4 GiB, host→guest | 244 MB/s | 233 MB/s |
| Drop file 1.5 GiB, host page-cache-warm | 381 MB/s (363.6 MiB/s) | — |
| Drop folder 4 GiB (one file), host→guest | 469 MB/s | 483 MB/s (wire 461 MiB/s) |
| Clipboard file 1.5 GiB, host→guest | 223 MB/s (212.5 MiB/s) | — |
| Clipboard file 1.5 GiB, guest→host | 144 MB/s sampled (137.5 MiB/s); ~190 MB/s est. unsampled | — |

Headline findings, each expanded below:

1. **The file path is device-read-latency-bound, not CPU-bound.** 78.4 % of the
   sender thread blocks in serial 64 KiB `read` calls on the `F_NOCACHE` fd
   (259 µs each ≈ 253 MB/s); the loop's compute ceiling is ~913 MB/s even at
   `-Onone`. The same file transfers at 381 MB/s while its pages are still in
   the host page cache (`F_NOCACHE` serves already-cached pages) and 212–244
   MB/s once evicted — run-to-run spread is cache state, not noise.
2. **The folder path outruns the file path ~2× on identical incompressible
   bytes** (483 vs 233 MB/s) because AppleArchive reads the tree with
   large-block, page-cached, multi-threaded I/O — compression is not the
   reason: LZFSE emitted 4,295,033,058 wire bytes for 4,294,967,296 logical
   (ratio 1.00002) while burning ~2.5 cores.
3. **Folder streaming starts only after a full pre-hash of the first entry.**
   `duration − streamingDuration` = 2.27 s for the 4.29 GB folder — exactly
   the file size over the measured 1.89 GB/s SHA-256 rate. The `SH2` entry
   field's digest sits in the entry *header*, so AppleArchive reads and hashes
   the whole file before the first payload byte can leave. This, plus drop
   serialization (a drop offered while another transfer is in flight waits —
   a 13 s queue was observed in the 2026-08-14 16:41 session), is the
   user-perceived "initial delay". The stream itself has no startup cost:
   offer→accept 3 ms, begin→first-chunk 1–13 ms on file paths.
4. **The displayed folder rate is logical (pre-compression) bytes per second;
   the wire carries compressed bytes.** A zero-filled 15 GiB test tree showed
   ~1.3 GB/s on screen (real logical progress) while the wire moved almost
   nothing. The guest's metrics line reports wire bytes — divide to get the
   ratio.
5. **Build configuration is irrelevant to throughput today.** Release vs Debug
   is within run noise on both paths; the profile attributes only ~3 % of the
   sender thread to the `-Onone` tax. Everything hot is compiler-invariant:
   syscalls, corecrypto, protocol waits. (BUILD.md's "Xcode-launched
   ~45–52 MiB/s" figure predates the `SO_SNDBUF` unlock and no longer holds;
   Xcode-attached runs today reach 212–255 MB/s.)
6. **The 1 MiB credit window is now a first-order limiter on the folder path**:
   29.5 % of its sender thread waits in `awaitCredit` (the window drains in
   ~3 ms at these rates), and another 26.5 % waits on the 1 MiB archive pipe
   hand-off. The 2026-07-13 note's "no window change needed" held for the
   transport; it no longer holds for the app stack.
7. **The guest→host cap is not on the host.** During a 137.5 MiB/s (sampled)
   guest→host paste the host's three receive lanes are 14 %/13 %/9 % busy —
   ~86 % starved. The limiter is the guest-side sender (the same serial
   `F_NOCACHE` read loop, against virtio-blk) and the ack cadence. Host
   receive costs 3.0 s CPU/GB vs 1.3 on send (three-copy decode chain, two
   GCD hops per chunk, per-MiB free-space stat).
8. **A guest→host paste blocks the host main thread for the whole pull.** The
   pasteboard promise callback (`LazyClipboardDataProvider` →
   `performBlockingPull` → `DispatchSemaphore.wait`) parked the main run loop
   for the full 11 s transfer — no UI, and the whole pull runs inside
   Finder's promise deadline window.
9. **`sample(1)` itself costs throughput on this pipeline**: −43 % at 1 ms
   interval, −24 % at 10 ms (Debug, file path). Profiles are valid for
   attribution; rates from sampled runs need that correction. `sample` also
   undershoots its interval (requested 10 ms → effective ~13 ms).

## Method

UI-driven end-to-end runs against a running VM — not the 2026-07-13 raw-
transport lab — so every number includes protobuf framing, SHA-256, staging,
and the real consumers (Finder drags, pasteboard promises):

- Host app launched standalone via `open` (no debugger); Debug and Release
  builds of the same commit (9e02b0a). Guest agent 0.62.0 as installed
  (unchanged across runs; its build config is a caveat on guest-side CPU
  claims, not on the host-side profile).
- Timing from the unified log: `VsockDropService` offer/streaming/completed
  lines host-side, and the receiver's `ClipboardTransferMetrics.logSummary`
  (`duration`, `streamingDuration`, byte count — wire bytes for a folder).
  **Forward guest logs** on the VM makes the guest agent's metrics lines
  land in the host store under `app.kernova.guest` — this is what makes
  host→guest transfers measurable without touching the guest.
- Profiles: `sample Kernova 30 10 -f <file>` during a transfer; four samples
  (file 1 ms, file 10 ms, folder 10 ms, guest→host receive 10 ms) analyzed
  by per-thread sample counts. SHA-256 measured 1.84–1.89 GB/s independently
  in three samples, validating the timing model.
- Payloads: `dd if=/dev/urandom` — 4 GiB file, the same file APFS-cloned into
  a folder (identical bytes both paths), 1.5 GiB file for clipboard runs
  (the 2 GiB paste cap refuses larger file sets on both sides).
- Caveats: host page-cache state dominates file-path variance (see finding 1)
  and was not controlled per run; drops and pastes were driven through real
  UI; Xcode idled in the background. Guest-side threads are invisible to
  `sample` (the guest runs in Apple's helper process).
- A zero-filled payload turns the folder path into a compressor benchmark and
  is unusable for throughput baselines.

## Prior conclusions, re-validated against the post-#714 engine

| Prior claim (pre-#714) | Status now |
|---|---|
| `SO_SNDBUF` unlock: 64 KiB writes optimal, transport ≫ app stack | **Holds.** vsock `write` is 3.1–4.9 % of the sender thread (~6.3 GB/s effective); transport never binds. |
| Chunk/window changes ruled out | **Overturned for the window.** Ruled out at transport level, but the 1 MiB credit window now costs the folder path 29.5 % sender idle. Chunk *size* on the wire remains fine; the serial 64 KiB *read* size is the file path's cap. |
| Parallel streams ruled out | **Holds.** No path saturates a single stream's compute; parallelism would add nothing before the read stall and window are fixed. |
| `F_NOCACHE` send-side reads acceptable | **Overturned.** It is the file path's dominant cost — and it also explains the cache-warm 381 MB/s outlier (F_NOCACHE still serves cached pages). |
| No-`fsync` staging writes | **Holds** (unchanged; staging `write` sustains 1.06 GB/s, 7× the achieved guest→host rate). |
| Digest dedup pulls its weight | Not re-measured; code path unchanged. |
| Materialized-rep cache pulls its weight | **Re-confirmed.** A second paste of the same generation produced the file with no second transfer. |
| guest→host ~750 MiB/s transport cap is OS-side | **Still standing as prior** (not re-measured); the app's guest→host stack (~190 MB/s est.) remains far below it, so it is not the active constraint. |

## Levers, ranked by measured headroom

1. **File-path source reads: prefetch/overlap/enlarge, or drop `F_NOCACHE`.**
   78 % of the sender thread; arithmetic ceiling moves from ~250 MB/s (device
   latency) toward the ~913 MB/s compute bound. The same serial-read loop in
   the guest agent is the guest→host cap. `NSFileHandle` also pays an `fstat`
   per read — read the raw fd.
2. **Drop the `SH2` field key from the archive key set.** Removes the
   full pre-read+hash before streaming (the 2.27 s startup delay), removes a
   duplicate whole-payload SHA-256 (22.7 % of the folder sender thread plus a
   dedicated worker), and removes nothing the stream-level digest doesn't
   already guarantee — CLIPBOARD.md §7's end-to-end hash is the wire digest,
   which stays.
3. **Co-scale the credit window with observed rate** (CLIPBOARD.md §8's "one
   tuning pair"): 29.5 % folder-path sender idle at 1 MiB. The ack path also
   crosses main-queue hops on both sides — worth moving off the latency path.
4. **Unblock the main thread on guest→host paste**: fulfil the promise
   asynchronously instead of `DispatchSemaphore.wait` inside `provideData`.
   UX and deadline-safety, not throughput.
5. **Compression policy**: LZFSE burned 2.5 cores to grow 4 GiB by 65 KB. An
   adaptive choice (sample the ratio, fall back to store-only) or LZ4 keeps
   the compressible-tree win without the incompressible-tree waste.
6. Smaller, profile-visible but not currently binding: the three-copy receive
   decode chain (~9 % of receive CPU), two GCD hops per chunk, the per-MiB
   free-space `stat` in the file write lane's ack path (~100 µs each, 8.3 %
   of that lane; the folder path already checks off-lane), the extra
   `Data` in `VsockFrame.encode`, protobuf's zero-filled output buffer, and
   the per-chunk unthrottled progress bookkeeping under three locks.

## Refactor assessment (required outcome)

Keep the unified lazy-always engine — it is validated here (the folder path
pushes 483 MB/s end-to-end through the same framing, hashing, and credit
machinery). The restructuring that pays is at the edges, not the core:

- **One prefetching chunk-source abstraction** feeding the sender: a bounded
  ring (2–4 chunks) filled by a reader stage, consumed by hash+frame+write.
  The archive path already has a bounded pipe; the file path has nothing.
  Unifying them removes the file path's read stall and the pipe's lock-step
  hand-off in one structure, and makes the sender testable against a
  synthetic source.
- **Ack handling off the main-queue routing hop**, and the free-space guard
  budget-based (as the folder path already does) instead of per-MiB in the
  ack path.
- **Quantized progress**: deliver progress at ack-quantum granularity instead
  of per 64 KiB chunk through three locks.

Not recommended: rewriting the channel/framing layer (write side measures
6.3 GB/s), replacing SwiftProtobuf (≤3 % everywhere), or parallel streams.

## Paste-cap re-derivation

`ClipboardPasteLimit.measuredThroughputBytesPerSecond` (366 MiB/s) is above
every file-path rate measured here (137–363 MiB/s depending on direction and
cache state). At the worst measured sustained rate (~137 MiB/s guest→host
sampled), 2 GiB streams in ~15 s — still >3× margin under the 60 s Finder
promise deadline, so the 2 GiB default stands. Re-derive the constant after
the read-path work lands rather than lowering it now; lowering it would only
shrink the user-visible estimate, not change safety.

## Instrumentation gaps confirmed

- Transfer metrics exist on receivers only; the send side logs a start line
  with no completion, duration, or rate — the host→guest direction is
  unmeasurable from the host without guest log forwarding.
- No `os_signpost` anywhere; stage-level attribution (read/hash/frame/write,
  time-to-first-chunk, credit stalls) required `sample` archaeology that
  signposts would give directly.
- `ClipboardTransferMetrics` does not separate time-to-first-chunk from
  streaming time on the *send* side, where the folder path's 2.27 s pre-hash
  lives.
