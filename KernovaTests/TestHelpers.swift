import Foundation
import Darwin
import KernovaProtocol

// Shared timing/test primitives for the KernovaTests bundle. Mirrors the
// shape of `KernovaGuestAgentTests/TestHelpers.swift` so the two bundles
// give the same diagnostic detail (timeout vs EOF) when frame waits fail.
//
// Xcode 16 synchronized folders make each bundle's files target-private,
// so a single file can't be shared across both — the duplication here is
// deliberate. Keep these signatures aligned with the GuestAgent variant.

// MARK: - TestFailure

struct TestFailure: Error {
    let message: String
    init(_ m: String) { message = m }
}

// MARK: - Socket / channel factories

/// Returns a connected AF_UNIX socketpair as two raw file descriptors.
func makeRawSocketPair() throws -> (Int32, Int32) {
    var fds: [Int32] = [-1, -1]
    let rc = fds.withUnsafeMutableBufferPointer { buf in
        socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
    }
    guard rc == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return (fds[0], fds[1])
}

// MARK: - waitUntil

/// Polls `predicate` every 10 ms until it returns `true` or `timeout` elapses.
///
/// Default deadline is generous (5 s) to absorb MainActor scheduling jitter on
/// CI runners. See feedback memory `feedback_ci_test_timings`.
///
/// `@MainActor`-isolated because every test in `KernovaTests` is MainActor and
/// the predicates routinely close over MainActor-isolated state (services,
/// view models). Keeping the helper on the same actor sidesteps Swift 6's
/// non-Sendable-closure errors on MainActor → nonisolated boundaries.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    _ predicate: () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !predicate() && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard predicate() else {
        throw TestFailure("Predicate did not become true within \(timeout)")
    }
}

// MARK: - nextFrame

/// Reads the next frame from `channel`, distinguishing timeout from EOF.
///
/// - Throws: `TestFailure("Timed out…")` when no frame arrives within `timeout`.
/// - Throws: `TestFailure("Channel finished…")` when the channel closes without
///   producing a frame (EOF), so the two failure shapes are identifiable in
///   post-mortem logs. Conflating them once masked a CI flake as a
///   peer-disconnect bug.
@MainActor
func nextFrame(
    from channel: VsockChannel,
    timeout: Duration = .seconds(5)
) async throws -> Frame {
    let receiver = Task<Frame?, Error> {
        var iterator = channel.incoming.makeAsyncIterator()
        return try await iterator.next()
    }
    let timeoutTask = Task<Void, Never> {
        try? await Task.sleep(for: timeout)
        receiver.cancel()
    }
    defer { timeoutTask.cancel() }

    do {
        guard let frame = try await receiver.value else {
            throw TestFailure("Channel finished without producing a frame (EOF)")
        }
        return frame
    } catch is CancellationError {
        throw TestFailure("Timed out waiting for a frame after \(timeout)")
    }
}
