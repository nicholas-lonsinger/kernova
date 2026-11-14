import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// Unit tests for `ClipboardProgressAutoReveal` — the rules that let a transfer
/// someone is waiting on show its readout in the status item's callout by
/// itself, once.
@Suite("ClipboardProgressAutoReveal", .caseScoped)
struct ClipboardProgressAutoRevealTests {
    /// The operation most tests follow, minted before any a test mints itself.
    private let operation = ClipboardTransferOperationID()

    /// A readout that clears every gate, so each test varies only what it is about.
    ///
    /// Outbound, the shape a paste readout has: this side is streaming the bytes
    /// an app on the peer is blocked on.
    private func readout(
        elapsed: TimeInterval = 5, secondsRemaining: Double? = 10, bytesTransferred: UInt64 = 100,
        gesture: ClipboardTransferGesture = .peerPaste, of other: ClipboardTransferOperationID? = nil
    ) -> ClipboardProgressSnapshot {
        ClipboardProgressSnapshot(
            direction: .outbound, peerName: "VM", currentItemName: nil, filesCompleted: 0,
            fileCount: 1, bytesTransferred: bytesTransferred, totalBytes: 1_000,
            bytesPerSecond: 100, secondsRemaining: secondsRemaining, gesture: gesture,
            elapsedSeconds: elapsed, operationID: other ?? operation)
    }

    /// Folds `readout` in with a callout that goes up when `shows`, and counts
    /// how often the callout was asked for.
    private static func fold(
        _ readout: ClipboardProgressSnapshot?, into reveal: inout ClipboardProgressAutoReveal,
        shows: Bool = true, asked: inout Int
    ) -> ClipboardProgressRevealDecision {
        reveal.readoutChanged(readout, dropdownIsOpen: false) {
            asked += 1
            return shows
        }
    }

    /// `fold` for a test that does not count the asks.
    private static func fold(
        _ readout: ClipboardProgressSnapshot?, into reveal: inout ClipboardProgressAutoReveal, shows: Bool = true
    ) -> ClipboardProgressRevealDecision {
        var asked = 0
        return fold(readout, into: &reveal, shows: shows, asked: &asked)
    }

    @Test("a callout that went up is the operation's one reveal")
    func revealsOncePerOperation() {
        var reveal = ClipboardProgressAutoReveal()
        var asked = 0
        #expect(Self.fold(readout(), into: &reveal, asked: &asked) == .shown)
        #expect(Self.fold(readout(), into: &reveal, asked: &asked) == .none)
        #expect(asked == 1)
    }

    @Test("a readout that clears and returns for the same operation never reveals again")
    func aClearedAndReturnedReadoutStaysSpent() {
        var reveal = ClipboardProgressAutoReveal()
        var asked = 0
        #expect(Self.fold(readout(), into: &reveal, asked: &asked) == .shown)
        // A concurrent operation's refusal publishes between two of this
        // operation's updates, and the readout clears for that one pass.
        #expect(Self.fold(nil, into: &reveal, asked: &asked) == .none)
        #expect(Self.fold(readout(), into: &reveal, asked: &asked) == .none)
        #expect(asked == 1)
    }

    @Test("a surface that goes back to an earlier operation never reveals it again")
    func anEarlierOperationStaysSpent() {
        var reveal = ClipboardProgressAutoReveal()
        var asked = 0
        #expect(Self.fold(readout(), into: &reveal, asked: &asked) == .shown)
        let later = ClipboardTransferOperationID()
        #expect(Self.fold(readout(of: later), into: &reveal, asked: &asked) == .shown)

        // The later operation ends, and the surface shows the first one again.
        #expect(Self.fold(readout(), into: &reveal, asked: &asked) == .none)
        #expect(asked == 2)
    }

    @Test("a status item that becomes reachable can still reveal for the same paste")
    func revealableLaterInTheSamePaste() {
        var reveal = ClipboardProgressAutoReveal()
        // The reveal is spent only when the callout actually goes up, so a paste
        // that started while the item was crowded out of the menu bar still gets
        // its callout once there is room.
        #expect(Self.fold(readout(), into: &reveal, shows: false) == .notShown)
        #expect(Self.fold(readout(), into: &reveal) == .shown)
    }

    // MARK: - Worth-revealing gate

    @Test("a transfer nobody is waiting on never reveals itself")
    func unawaitedGestureNeverReveals() {
        var reveal = ClipboardProgressAutoReveal()
        var asked = 0
        #expect(Self.fold(readout(gesture: .paste), into: &reveal, asked: &asked) == .none)
        #expect(asked == 0)
    }

    @Test("a drop takes its one reveal and no more, however long it runs")
    func aDropRevealsOnlyOnce() {
        var reveal = ClipboardProgressAutoReveal()
        var asked = 0
        #expect(
            Self.fold(
                readout(elapsed: 3, secondsRemaining: 600, gesture: .drop), into: &reveal,
                asked: &asked) == .shown)
        for elapsed in [30.0, 300.0] {
            #expect(
                Self.fold(
                    readout(elapsed: elapsed, secondsRemaining: 600, gesture: .drop),
                    into: &reveal, asked: &asked) == .none)
        }
        #expect(asked == 1)
    }

    @Test("a paste with no rate estimate yet still reveals itself")
    func unknownRateReveals() {
        var reveal = ClipboardProgressAutoReveal()
        // Past the elapsed floor with nothing measurable is a stalled or very slow paste,
        // not one about to finish.
        #expect(Self.fold(readout(secondsRemaining: nil), into: &reveal) == .shown)
    }

    @Test("a readout that time alone will not earn the reveal names no moment")
    func namesNoMomentWhenTimeAloneWillNot() {
        let reveal = ClipboardProgressAutoReveal()
        // Already past the floor: the delivered update decided it.
        #expect(reveal.secondsUntilEarned(readout(elapsed: 5)) == nil)
        // Its estimate runs out before the floor.
        #expect(reveal.secondsUntilEarned(readout(elapsed: 0.25, secondsRemaining: 1)) == nil)
        // Every byte in.
        #expect(
            reveal.secondsUntilEarned(
                readout(elapsed: 0.25, secondsRemaining: nil, bytesTransferred: 1_000)) == nil)
        // Nobody is waiting on it.
        #expect(reveal.secondsUntilEarned(readout(elapsed: 0.25, gesture: .preview)) == nil)
    }
}
