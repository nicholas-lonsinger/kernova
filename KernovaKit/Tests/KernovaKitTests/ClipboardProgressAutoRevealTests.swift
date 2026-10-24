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
        totalBytes: UInt64 = 1_000, gesture: ClipboardTransferGesture = .peerPaste,
        of other: ClipboardTransferOperationID? = nil
    ) -> ClipboardProgressSnapshot {
        ClipboardProgressSnapshot(
            direction: .outbound, peerName: "VM", currentItemName: nil, filesCompleted: 0,
            fileCount: 1, bytesTransferred: bytesTransferred, totalBytes: totalBytes,
            bytesPerSecond: 100, secondsRemaining: secondsRemaining, gesture: gesture,
            elapsedSeconds: elapsed, operationID: other ?? operation)
    }

    /// Folds `readout` in with a callout that goes up when `shows`, and counts
    /// how often the callout was asked for.
    private static func fold(
        _ readout: ClipboardProgressSnapshot?, into reveal: inout ClipboardProgressAutoReveal,
        dropdownIsOpen: Bool = false, shows: Bool = true, asked: inout Int
    ) -> ClipboardProgressRevealDecision {
        reveal.readoutChanged(readout, dropdownIsOpen: dropdownIsOpen) {
            asked += 1
            return shows
        }
    }

    /// `fold` for a test that does not count the asks.
    private static func fold(
        _ readout: ClipboardProgressSnapshot?, into reveal: inout ClipboardProgressAutoReveal,
        dropdownIsOpen: Bool = false, shows: Bool = true
    ) -> ClipboardProgressRevealDecision {
        var asked = 0
        return fold(readout, into: &reveal, dropdownIsOpen: dropdownIsOpen, shows: shows, asked: &asked)
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

    @Test("an operation that follows another with no gap earns its own reveal")
    func aFollowingOperationReveals() {
        var reveal = ClipboardProgressAutoReveal()
        #expect(Self.fold(readout(), into: &reveal) == .shown)

        let next = ClipboardTransferOperationID()
        #expect(Self.fold(readout(of: next), into: &reveal) == .shown)
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

    @Test("a readout that appeared inside an open dropdown never raises a callout later")
    func anOpenDropdownSpendsTheReveal() {
        var reveal = ClipboardProgressAutoReveal()
        var asked = 0
        // The user opened the dropdown for their own reasons, and the paste's
        // readout then appeared inside it — so the paste has had its showing.
        #expect(Self.fold(readout(), into: &reveal, dropdownIsOpen: true, asked: &asked) == .none)

        // Dismissing it is the user saying no. The next throttled update must not
        // answer that with a callout.
        #expect(Self.fold(readout(), into: &reveal, asked: &asked) == .none)
        #expect(asked == 0)
    }

    @Test("an open dropdown spends only the reveal of the operation it showed")
    func anOpenDropdownSpendsOnlyItsOperation() {
        var reveal = ClipboardProgressAutoReveal()
        #expect(Self.fold(readout(), into: &reveal, dropdownIsOpen: true) == .none)

        let next = ClipboardTransferOperationID()
        #expect(Self.fold(readout(of: next), into: &reveal) == .shown)
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

    @Test("a clear asks for no callout")
    func clearIsInert() {
        var reveal = ClipboardProgressAutoReveal()
        var asked = 0
        #expect(Self.fold(nil, into: &reveal, asked: &asked) == .none)
        #expect(asked == 0)
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

    @Test("a readout nobody is waiting on does not spend the one reveal, even in an open menu")
    func unawaitedReadoutDoesNotSpendTheReveal() {
        var reveal = ClipboardProgressAutoReveal()
        // A preview fetch reveals while the dropdown happens to be open. If that
        // spent the reveal, a paste following it would never get its showing.
        #expect(Self.fold(readout(gesture: .paste), into: &reveal, dropdownIsOpen: true) == .none)
        let paste = ClipboardTransferOperationID()
        #expect(Self.fold(readout(of: paste), into: &reveal) == .shown)
    }

    @Test("a paste held back for being too young still reveals once it has run long enough")
    func youngPasteRevealsLater() {
        var reveal = ClipboardProgressAutoReveal()
        var asked = 0
        // Holding back must not spend the reveal — the readout was never shown.
        #expect(Self.fold(readout(elapsed: 0.5), into: &reveal, asked: &asked) == .none)
        #expect(asked == 0)
        #expect(Self.fold(readout(elapsed: 1.5), into: &reveal, asked: &asked) == .shown)
    }

    @Test("a paste that turns out slower than its early estimate still earns the reveal")
    func slowingPasteRevealsLater() {
        var reveal = ClipboardProgressAutoReveal()
        // The estimate said it was nearly over, so the reveal was withheld; it
        // then slowed down, which is exactly when a standing readout earns its
        // place.
        #expect(Self.fold(readout(secondsRemaining: 0.5), into: &reveal) == .none)
        #expect(Self.fold(readout(secondsRemaining: 30), into: &reveal) == .shown)
    }

    @Test("a paste whose bytes are all in does not reveal itself")
    func allBytesInDoesNotReveal() {
        var reveal = ClipboardProgressAutoReveal()
        // `secondsRemaining` reads nil both here and before a rate exists, so the
        // completion check has to come first or this would be taken for "unknown".
        #expect(
            Self.fold(
                readout(secondsRemaining: nil, bytesTransferred: 1_000, totalBytes: 1_000),
                into: &reveal) == .none)
    }

    @Test("a paste with no rate estimate yet still reveals itself")
    func unknownRateReveals() {
        var reveal = ClipboardProgressAutoReveal()
        // Past the elapsed floor with nothing measurable is a stalled or very slow paste,
        // not one about to finish.
        #expect(Self.fold(readout(secondsRemaining: nil), into: &reveal) == .shown)
    }

    @Test("a paste with no byte total to estimate against still reveals itself")
    func zeroTotalReveals() {
        var reveal = ClipboardProgressAutoReveal()
        #expect(
            Self.fold(
                readout(secondsRemaining: nil, bytesTransferred: 0, totalBytes: 0),
                into: &reveal) == .shown)
    }

    @Test("a drag whose total waits on a folder's size reveals on the elapsed floor alone")
    func awaitedSizeReveals() {
        var reveal = ClipboardProgressAutoReveal()
        // An item already in makes the partial total look complete.
        let waiting = ClipboardProgressSnapshot(
            direction: .inbound, peerName: "VM", currentItemName: nil, filesCompleted: 1,
            fileCount: 2, bytesTransferred: 1_000, totalBytes: 1_000, bytesPerSecond: nil,
            secondsRemaining: nil, gesture: .dragOut, elapsedSeconds: 5, operationID: operation,
            awaitsSize: true)
        #expect(Self.fold(waiting, into: &reveal) == .shown)
    }

    @Test("the shipped thresholds hold a short paste back and let a longer one through")
    func shippedThresholds() {
        // Exercises the defaults rather than an injected pair, so the numbers that
        // actually ship are covered.
        #expect(ClipboardProgressAutoReveal.defaultMinimumElapsedToReveal == 1)
        #expect(ClipboardProgressAutoReveal.defaultMinimumRemainingToReveal == 1)

        // The case that prompted the gate: a copy just past the elapsed floor with
        // less than the callout's own lifetime left to run.
        var tooShort = ClipboardProgressAutoReveal()
        #expect(Self.fold(readout(elapsed: 1.1, secondsRemaining: 0.7), into: &tooShort) == .none)

        var longEnough = ClipboardProgressAutoReveal()
        #expect(Self.fold(readout(elapsed: 1.1, secondsRemaining: 120), into: &longEnough) == .shown)
    }
}
