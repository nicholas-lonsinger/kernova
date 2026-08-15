# Stream credit window and archive pipes: a parametric sweep

**Date:** 2026-08-15 · **Hardware:** M1 Max, 32 GB, macOS 27.0 host ·
**Seam:** KernovaKit `StreamHarness` over an `AF_UNIX` socketpair, Debug ·
**Tracking issue:** #859

## Summary

Until this pass one constant sized four things: the sender's encode-pipe
capacity, the in-flight credit window, the receiver's extract-pipe capacity,
and the extract's output-guard quantum. This sweep separates them and moves one
at a time, against a modelled ack round trip.

1. **Only the credit window moves throughput.** Encode-pipe and extract-pipe
   capacity are flat from 1 MiB to 16 MiB in every regime tested: 558–563 MiB/s
   across all seven combinations at zero modelled round trip, and 278–296 MiB/s
   across the same seven at 2 ms, where the sender is credit-bound. Deeper pipes
   cannot rescue a credit-bound sender, and add nothing to one that is not.
2. **The window's effect is exactly `min(pipeline ceiling, W / RTT)`.** The
   ceiling on this seam is ~575 MiB/s, and each window holds full rate until
   `W / RTT` falls under it: 1 MiB collapses between 1 and 2 ms, 2 MiB between
   2 and 4 ms, 4 MiB between 4 and 8 ms, and 8 MiB is still at full rate at
   8 ms. Credit stall accounts for the whole loss — 1.24 s of a 1.64 s transfer
   at 1 MiB and 8 ms.
3. **The credit window costs no resident memory against a sink that keeps
   up.** Peak `phys_footprint` delta is 0.5–1.5 MiB at every window from 1 to
   8 MiB, indistinguishable from run noise, because the sender frames and
   releases each chunk and the receiver's write lane drains as fast as it
   fills. Against a sink slower than the wire the receiving side retains up to
   a window per transfer — every configuration swept had a fast sink, so that
   case is outside these numbers.
4. **The file path and the folder path are one path.** Identical chunk counts
   and wire bytes, and rates within 2 % of each other at every configuration —
   what #866 did, measured.

**Values chosen from this:** credit window 1 → 4 MiB with its cap 2 → 8 MiB,
which buys ~4× the round-trip headroom at a bounded memory cost. Both pipes
and the guard quantum stay at 1 MiB, on the null in finding 1.

## What was and was not measured

Measured: the real `ClipboardStreamSender` and `ClipboardStreamReceiver`, the
real LZ4 archive encode and extract pipelines, real APFS staging and the
end-to-end SHA-256, over a real socketpair.

Not measured: the virtio-vsock hop, any VM, guest-side CPU and disk, and
host↔guest asymmetry. **The round trip is a model, not a measurement of the
wire** — production's own ack round trip is not established here, so no product
throughput figure follows from this note. What follows is the sensitivity
curve, and the observation that the shipped window's knee sits at ~1.75 ms.

## Why the round trip became an axis

The first pass swept the three sizes with no modelled round trip at all and
returned a null on all three: every configuration landed within a few percent,
and credit stall was ~1 % of wall time everywhere, including at the shipped
1 MiB window. That null is a property of the seam, not of the constant — a
socketpair's ack round trip is microseconds, so the credit loop cannot bind,
and a sweep run there can only ever report that it does not.

Making the round trip an explicit axis is what turns "the window does not bind
here" into a rule that transfers: the window binds when `W / RTT` drops below
the achievable rate, and each doubling doubles the round trip absorbed.

## Decision rule

Fixed before the numbers were read: adopt a larger value for an axis only if
the median rate improves by ≥ 10 % on at least one path, no path regresses by
more than 2 %, and the peak-footprint increase is accounted for. The pipes fail
it at every round trip (largest effect 1.4 %, inside noise). The window clears
it wherever the round trip binds and is neutral where it does not.

## Marginal cost

Per concurrent transfer, against what shipped before:

- Heap: unchanged. Encode pipe 1 MiB on the sending side, extract pipe 1 MiB on
  the receiving side, both untouched.
- In flight: up to the window in unacked bytes, in kernel socket buffers and on
  the receiver's write lane — 1 MiB → 4 MiB.
- Misbehaving-peer allowance (`maxBacklogBytes`, window + 16 MiB): 17 → 20 MiB
  at the default, 18 → 24 MiB at the cap.

## Results

`E` is the encode pipe, `X` the extract pipe, `W` the credit window, `rtt` the
modelled ack round trip. Rate is payload bytes over whole-transfer wall clock,
median of three runs after one discarded warm-up run per path. Payload is
`/dev/urandom` — 128 MiB as one file, and as a folder of eight 16 MiB files.
Sweep A moves the window against the round trip with both pipes pinned at
1 MiB; sweep B moves the pipes at a round trip where the window binds and at
one where it does not.

| sweep | path | config | MiB/s | wall s | credit s | source s | ttfc s | chunks | wire MiB | footprint Δ MiB |
|---|---|---|---|---|---|---|---|---|---|---|
| A | file | E=1 X=1 W=1 rtt=0.0ms | 437.6 | 0.293 | 0.003 | 0.016 | 0.004 | 2049 | 128.0 | 11.1 |
| A | file | E=1 X=1 W=1 rtt=1.0ms | 461.3 | 0.277 | 0.015 | 0.015 | 0.002 | 2049 | 128.0 | 10.6 |
| A | file | E=1 X=1 W=1 rtt=2.0ms | 274.8 | 0.466 | 0.210 | 0.015 | 0.003 | 2049 | 128.0 | 0.9 |
| A | file | E=1 X=1 W=1 rtt=4.0ms | 177.4 | 0.722 | 0.487 | 0.015 | 0.006 | 2049 | 128.0 | 2.7 |
| A | file | E=1 X=1 W=1 rtt=8.0ms | 78.1 | 1.640 | 1.236 | 0.018 | 0.011 | 2049 | 128.0 | 2.9 |
| A | file | E=1 X=1 W=2 rtt=0.0ms | 568.1 | 0.225 | 0.003 | 0.013 | 0.002 | 2049 | 128.0 | 0.8 |
| A | file | E=1 X=1 W=2 rtt=1.0ms | 571.0 | 0.224 | 0.003 | 0.013 | 0.003 | 2049 | 128.0 | 0.5 |
| A | file | E=1 X=1 W=2 rtt=2.0ms | 543.4 | 0.236 | 0.016 | 0.013 | 0.004 | 2049 | 128.0 | 0.5 |
| A | file | E=1 X=1 W=2 rtt=4.0ms | 313.5 | 0.408 | 0.182 | 0.013 | 0.006 | 2049 | 128.0 | 0.5 |
| A | file | E=1 X=1 W=2 rtt=8.0ms | 158.6 | 0.807 | 0.562 | 0.014 | 0.010 | 2049 | 128.0 | 0.5 |
| A | file | E=1 X=1 W=4 rtt=0.0ms | 574.2 | 0.223 | 0.003 | 0.013 | 0.002 | 2049 | 128.0 | 0.5 |
| A | file | E=1 X=1 W=4 rtt=1.0ms | 571.2 | 0.224 | 0.003 | 0.013 | 0.003 | 2049 | 128.0 | 0.5 |
| A | file | E=1 X=1 W=4 rtt=2.0ms | 570.4 | 0.224 | 0.004 | 0.013 | 0.004 | 2049 | 128.0 | 0.5 |
| A | file | E=1 X=1 W=4 rtt=4.0ms | 555.1 | 0.231 | 0.009 | 0.014 | 0.007 | 2049 | 128.0 | 0.0 |
| A | file | E=1 X=1 W=4 rtt=8.0ms | 311.6 | 0.411 | 0.191 | 0.013 | 0.011 | 2049 | 128.0 | 0.5 |
| A | file | E=1 X=1 W=8 rtt=0.0ms | 579.7 | 0.221 | 0.002 | 0.013 | 0.002 | 2049 | 128.0 | 0.6 |
| A | file | E=1 X=1 W=8 rtt=1.0ms | 577.1 | 0.222 | 0.003 | 0.013 | 0.003 | 2049 | 128.0 | 0.5 |
| A | file | E=1 X=1 W=8 rtt=2.0ms | 573.4 | 0.223 | 0.003 | 0.013 | 0.003 | 2049 | 128.0 | 0.5 |
| A | file | E=1 X=1 W=8 rtt=4.0ms | 567.1 | 0.226 | 0.006 | 0.014 | 0.006 | 2049 | 128.0 | 0.5 |
| A | file | E=1 X=1 W=8 rtt=8.0ms | 553.2 | 0.231 | 0.012 | 0.013 | 0.011 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=1 rtt=0.0ms | 562.8 | 0.227 | 0.003 | 0.013 | 0.003 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=1 rtt=1.0ms | 525.7 | 0.243 | 0.022 | 0.014 | 0.003 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=1 rtt=2.0ms | 279.6 | 0.458 | 0.238 | 0.014 | 0.004 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=1 rtt=4.0ms | 158.9 | 0.805 | 0.583 | 0.014 | 0.007 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=1 rtt=8.0ms | 81.6 | 1.570 | 1.290 | 0.016 | 0.010 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=2 rtt=0.0ms | 570.5 | 0.224 | 0.003 | 0.013 | 0.002 | 2049 | 128.0 | 1.0 |
| A | folder | E=1 X=1 W=2 rtt=1.0ms | 564.4 | 0.227 | 0.003 | 0.013 | 0.003 | 2049 | 128.0 | 1.0 |
| A | folder | E=1 X=1 W=2 rtt=2.0ms | 552.4 | 0.232 | 0.016 | 0.014 | 0.004 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=2 rtt=4.0ms | 302.0 | 0.424 | 0.205 | 0.013 | 0.006 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=2 rtt=8.0ms | 159.6 | 0.802 | 0.559 | 0.014 | 0.009 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=4 rtt=0.0ms | 575.7 | 0.222 | 0.003 | 0.013 | 0.002 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=4 rtt=1.0ms | 577.5 | 0.222 | 0.003 | 0.013 | 0.003 | 2049 | 128.0 | 1.0 |
| A | folder | E=1 X=1 W=4 rtt=2.0ms | 573.6 | 0.223 | 0.004 | 0.013 | 0.004 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=4 rtt=4.0ms | 563.5 | 0.227 | 0.008 | 0.013 | 0.006 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=4 rtt=8.0ms | 315.7 | 0.405 | 0.184 | 0.014 | 0.011 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=8 rtt=0.0ms | 576.2 | 0.222 | 0.003 | 0.013 | 0.002 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=8 rtt=1.0ms | 577.0 | 0.222 | 0.003 | 0.013 | 0.003 | 2049 | 128.0 | 0.8 |
| A | folder | E=1 X=1 W=8 rtt=2.0ms | 580.1 | 0.221 | 0.004 | 0.013 | 0.004 | 2049 | 128.0 | 0.7 |
| A | folder | E=1 X=1 W=8 rtt=4.0ms | 570.9 | 0.224 | 0.005 | 0.013 | 0.005 | 2049 | 128.0 | 0.5 |
| A | folder | E=1 X=1 W=8 rtt=8.0ms | 562.8 | 0.227 | 0.011 | 0.013 | 0.011 | 2049 | 128.0 | 0.5 |
| B | file | E=1 X=1 W=1 rtt=0.0ms | 560.0 | 0.229 | 0.002 | 0.014 | 0.002 | 2049 | 128.0 | 0.5 |
| B | file | E=1 X=1 W=1 rtt=2.0ms | 295.4 | 0.433 | 0.215 | 0.013 | 0.004 | 2049 | 128.0 | 0.8 |
| B | file | E=1 X=1 W=4 rtt=2.0ms | 572.2 | 0.224 | 0.003 | 0.014 | 0.003 | 2049 | 128.0 | 1.5 |
| B | file | E=4 X=1 W=1 rtt=0.0ms | 559.0 | 0.229 | 0.002 | 0.014 | 0.003 | 2049 | 128.0 | 1.5 |
| B | file | E=4 X=1 W=1 rtt=2.0ms | 292.6 | 0.437 | 0.218 | 0.014 | 0.004 | 2049 | 128.0 | 0.5 |
| B | file | E=4 X=1 W=4 rtt=2.0ms | 570.7 | 0.224 | 0.004 | 0.014 | 0.004 | 2049 | 128.0 | 0.5 |
| B | file | E=8 X=1 W=1 rtt=0.0ms | 559.3 | 0.229 | 0.002 | 0.014 | 0.002 | 2049 | 128.0 | 5.3 |
| B | file | E=8 X=1 W=1 rtt=2.0ms | 294.6 | 0.435 | 0.217 | 0.013 | 0.004 | 2049 | 128.0 | 0.5 |
| B | file | E=8 X=1 W=4 rtt=2.0ms | 566.7 | 0.226 | 0.004 | 0.013 | 0.004 | 2049 | 128.0 | 1.6 |
| B | file | E=16 X=1 W=1 rtt=0.0ms | 558.3 | 0.229 | 0.003 | 0.013 | 0.003 | 2049 | 128.0 | 3.5 |
| B | file | E=16 X=1 W=1 rtt=2.0ms | 296.4 | 0.432 | 0.209 | 0.013 | 0.004 | 2049 | 128.0 | 0.7 |
| B | file | E=16 X=1 W=4 rtt=2.0ms | 563.8 | 0.227 | 0.004 | 0.013 | 0.003 | 2049 | 128.0 | 0.8 |
| B | file | E=1 X=4 W=1 rtt=0.0ms | 562.7 | 0.227 | 0.002 | 0.013 | 0.002 | 2049 | 128.0 | 0.5 |
| B | file | E=1 X=4 W=1 rtt=2.0ms | 295.5 | 0.433 | 0.217 | 0.013 | 0.004 | 2049 | 128.0 | 0.5 |
| B | file | E=1 X=4 W=4 rtt=2.0ms | 558.3 | 0.229 | 0.004 | 0.014 | 0.004 | 2049 | 128.0 | 0.5 |
| B | file | E=1 X=8 W=1 rtt=0.0ms | 560.7 | 0.228 | 0.002 | 0.013 | 0.002 | 2049 | 128.0 | 0.8 |
| B | file | E=1 X=8 W=1 rtt=2.0ms | 278.9 | 0.459 | 0.239 | 0.013 | 0.003 | 2049 | 128.0 | 0.5 |
| B | file | E=1 X=8 W=4 rtt=2.0ms | 571.5 | 0.224 | 0.004 | 0.013 | 0.004 | 2049 | 128.0 | 0.5 |
| B | file | E=8 X=8 W=1 rtt=0.0ms | 560.2 | 0.229 | 0.003 | 0.013 | 0.002 | 2049 | 128.0 | 0.5 |
| B | file | E=8 X=8 W=1 rtt=2.0ms | 278.3 | 0.460 | 0.240 | 0.014 | 0.003 | 2049 | 128.0 | 0.5 |
| B | file | E=8 X=8 W=4 rtt=2.0ms | 566.1 | 0.226 | 0.004 | 0.013 | 0.004 | 2049 | 128.0 | 0.5 |

## Caveats

- **Sweep A's first block is warm.** Its `E=1 X=1 W=1 rtt=0.0ms` row reads
  437.6 MiB/s against 560.0 for the identical configuration in sweep B, and its
  first two rows are the only ones showing a ~10 MiB footprint delta — process
  first-touch, not the configuration. Read sweep B's row as the zero-round-trip
  baseline. One discarded warm-up run per path was not enough for the very
  first block.
- **One process, one machine.** Both ends plus encode and extract share the
  same cores, where production splits them across host and guest vCPUs. That
  pushes the CPU ceiling here below production's and gives the pipes their best
  chance to matter — and they still measured flat, which is what makes the null
  in finding 1 strong rather than weak.
- **Debug.** The 2026-08-14 baseline found build configuration within run noise
  on these paths, attributing ~3 % of the sender thread to the `-Onone` tax.
- These rates are not comparable to the 2026-08-14 end-to-end figures: a
  different seam, a different payload size, and no VM.

## Method

`make test-package`, with the sweep below added to `KernovaKitTests` and two
temporary edits, all three reverted afterwards:

1. `ClipboardStreamTuning.maxWindowBytes` raised to 16 MiB for the duration.
   The receiver clamps its advertisement to it, so without this the sweep
   cannot exceed the shipped cap.
2. `StreamHarness.init` gained an `ackDelay` parameter, applied where the
   harness routes an ack back to the sender. A serial queue with a constant
   offset is what makes this added latency rather than an ack rate cap:

```swift
if ackDelay > 0 {
    ackDelayQueue.asyncAfter(deadline: .now() + ackDelay) {
        sender.handleAck(
            transferID: admitted.transferID,
            bytesConsumed: admitted.bytesConsumed,
            windowBytes: admitted.windowBytes)
    }
} else {
    sender.handleAck(
        transferID: admitted.transferID,
        bytesConsumed: admitted.bytesConsumed,
        windowBytes: admitted.windowBytes)
}
```

Only the ack direction is delayed; chunks travel at the socketpair's own speed.
That is the credit loop's latency, which is the quantity the window trades
against.

3. The driver, in full:

```swift
import Darwin
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("ClipboardWindowSweep", .serialized)
struct ClipboardWindowSweepTests {
    private static let mib = 1024 * 1024
    private static let payloadBytes = 128 * mib
    private static let repetitions = 3

    private struct Config: Sendable {
        let encode: Int
        let extractPipe: Int
        let window: Int
        /// Modelled one-way ack latency, in seconds.
        let ackDelay: TimeInterval
        var label: String {
            let m = 1024 * 1024
            return String(
                format: "E=%d X=%d W=%d rtt=%.1fms", encode / m, extractPipe / m, window / m,
                ackDelay * 1000)
        }
    }

    private struct Run: Sendable {
        let wall: Double
        let creditStall: Double
        let sourceWait: Double
        let timeToFirstChunk: Double
        let inboundStreaming: Double
        let wireBytes: Int
        let chunkCount: Int
        let footprintDelta: Int
    }

    private static func writeRandomFile(at url: URL, bytes: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        let urandom = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/urandom"))
        defer { try? urandom.close() }
        var written = 0
        while written < bytes {
            let want = min(4 * mib, bytes - written)
            guard let block = try urandom.read(upToCount: want), !block.isEmpty else { break }
            try out.write(contentsOf: block)
            written += block.count
        }
    }

    private static func physFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    private final class FootprintSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var peak = 0
        private let baseline: Int

        init() {
            baseline = ClipboardWindowSweepTests.physFootprint()
            peak = baseline
            DispatchQueue.global(qos: .utility).async { [self] in
                while lock.withLock({ running }) {
                    let now = ClipboardWindowSweepTests.physFootprint()
                    lock.withLock { peak = max(peak, now) }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }

        func stop() -> Int {
            lock.withLock {
                running = false
                return peak - baseline
            }
        }
    }

    private func run(
        _ config: Config, sourceURL: URL, advertised: Int, directoryNamed: String?
    ) async throws -> Run {
        let harness = try StreamHarness(
            chunkSize: ClipboardStreamTuning.defaultChunkPayloadSize,
            windowBytes: config.window,
            encodePipeBytes: config.encode,
            extractPipeBytes: config.extractPipe,
            extractPacingBytes: Self.mib,
            ackDelay: config.ackDelay,
            freeSpaceProvider: { _ in 200 << 30 })
        defer { harness.tearDown() }

        let collector = harness.collector
        let id: UInt64 = 1
        harness.receiver.awaitTransfer(
            id, extractsDirectoryNamed: directoryNamed, advertisedByteCount: advertised,
            onComplete: { collector.complete(id, $0) },
            onAbort: { collector.abort($0) })

        let representation: ClipboardContent.Representation
        if let directoryNamed {
            representation = ClipboardContent.Representation(
                directorySourceURL: sourceURL,
                estimatedByteCount: ClipboardArchive.estimatedByteCount(at: sourceURL),
                filename: directoryNamed)
        } else {
            representation = ClipboardContent.Representation(
                uti: "public.data", fileURL: sourceURL, byteCount: advertised,
                filename: "sweep.bin")
        }

        let sampler = FootprintSampler()
        let started = Date()
        harness.sender.startTransfer(
            transferID: id, generation: 1, representation: representation,
            maxAcceptByteCount: .max, isInline: false, isCurrent: { _ in true })
        try await collector.gate.wait(timeout: 300) {
            collector.representation(id) != nil || collector.abortCount > 0
        }
        let wall = Date().timeIntervalSince(started)
        let footprintDelta = sampler.stop()

        #expect(collector.abortInfos.map(\.code) == [])
        let outbound = try #require(collector.outboundMetrics.first)
        let inbound = try #require(collector.inboundMetrics.first)
        var outboundDetail: ClipboardTransferMetrics.Outbound?
        if case .outbound(let detail) = outbound.detail { outboundDetail = detail }
        var inboundDetail: ClipboardTransferMetrics.Inbound?
        if case .inbound(let detail) = inbound.detail { inboundDetail = detail }
        let out = try #require(outboundDetail)
        let inb = try #require(inboundDetail)
        return Run(
            wall: wall,
            creditStall: out.creditStall,
            sourceWait: out.sourceWait,
            timeToFirstChunk: out.timeToFirstChunk ?? 0,
            inboundStreaming: inb.streamingDuration ?? 0,
            wireBytes: outbound.wireByteCount,
            chunkCount: out.chunkCount,
            footprintDelta: footprintDelta)
    }

    @Test("sweeps the pipes and the credit window against a modelled ack round trip")
    func sweep() async throws {
        let mib = Self.mib
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "window-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let file = scratch.appendingPathComponent("sweep.bin", isDirectory: false)
        try Self.writeRandomFile(at: file, bytes: Self.payloadBytes)

        let folder = scratch.appendingPathComponent("Tree", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<8 {
            try Self.writeRandomFile(
                at: folder.appendingPathComponent("part\(index).bin", isDirectory: false),
                bytes: Self.payloadBytes / 8)
        }

        let one = 1 * mib
        var sweepA: [Config] = []
        for window in [1, 2, 4, 8] {
            for rtt in [0.0, 0.001, 0.002, 0.004, 0.008] {
                sweepA.append(
                    Config(
                        encode: one, extractPipe: one, window: window * mib, ackDelay: rtt))
            }
        }
        var sweepB: [Config] = []
        for (encode, extractPipe) in [(1, 1), (4, 1), (8, 1), (16, 1), (1, 4), (1, 8), (8, 8)] {
            for (window, rtt) in [(1, 0.0), (1, 0.002), (4, 0.002)] {
                sweepB.append(
                    Config(
                        encode: encode * mib, extractPipe: extractPipe * mib,
                        window: window * mib, ackDelay: rtt))
            }
        }

        var lines: [String] = []

        func measure(
            _ name: String, _ configs: [Config], _ pathName: String, _ sourceURL: URL,
            _ directory: String?
        ) async throws {
            _ = try await run(
                Config(encode: one, extractPipe: one, window: one, ackDelay: 0),
                sourceURL: sourceURL, advertised: Self.payloadBytes, directoryNamed: directory)
            for config in configs {
                var runs: [Run] = []
                for _ in 0..<Self.repetitions {
                    runs.append(
                        try await run(
                            config, sourceURL: sourceURL, advertised: Self.payloadBytes,
                            directoryNamed: directory))
                }
                let sorted = runs.sorted { $0.wall < $1.wall }
                let median = sorted[sorted.count / 2]
                let rate = Double(Self.payloadBytes) / Double(mib) / median.wall
                lines.append(
                    String(
                        format:
                            "| %@ | %@ | %@ | %.1f | %.3f | %.3f | %.3f | %.3f | %d | %.1f | %.1f |",
                        name, pathName, config.label, rate, median.wall, median.creditStall,
                        median.sourceWait, median.timeToFirstChunk, median.chunkCount,
                        Double(median.wireBytes) / Double(mib),
                        Double(median.footprintDelta) / Double(mib)))
            }
        }

        try await measure("A", sweepA, "file", file, nil)
        try await measure("A", sweepA, "folder", folder, "Tree")
        try await measure("B", sweepB, "file", file, nil)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kernova-window-sweep.md", isDirectory: false)
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        print("SWEEP-RESULTS: \(out.path)")
    }
}
```

## Open

Production's ack round trip over virtio-vsock is the one number that places the
shipped stream on the curve above, and it is not measurable from this seam. An
end-to-end run against a live VM, reading `creditStall` out of the metrics line
at 4 MiB, is what would settle whether the window still binds after this change
— and whether the `VsockChannel` ack fast path is worth its ordering risk.
