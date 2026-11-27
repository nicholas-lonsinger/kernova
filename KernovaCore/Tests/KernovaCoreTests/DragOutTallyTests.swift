import KernovaKit
import KernovaTestSupport
import KernovaTransferProgress
import Testing

@testable import KernovaCore

/// The drag-out tally's account, kept as each item's write ends, against the account worked out from scratch
/// from what every item came to last.
@Suite("DragOutTally", .caseScoped)
struct DragOutTallyTests {
    /// The account of `outcomes`, a drag of `items` items, counted from scratch.
    private static func account(of outcomes: [Int: DragOutTally.Outcome], items: Int) -> DragOutAccount {
        var account = DragOutAccount(items: items)
        var landedIn: Set<String> = []
        var refusedIn: Set<String> = []
        for outcome in outcomes.values {
            switch outcome {
            case .landed(let folder):
                account.landed += 1
                landedIn.insert(folder)
            case .failed(.refused, let folder, let promised):
                account.refused += 1
                refusedIn.insert(folder)
                if promised { account.refusedPromise = true }
            case .failed(.unreadable, _, _): account.unreadable += 1
            case .failed(.unwritable, _, _): account.unwritable += 1
            case .failed(.unsupplied, _, _): account.unsupplied += 1
            case .failed(.failed, _, _): account.failed += 1
            }
        }
        account.refusedBesideLanded = !landedIn.isDisjoint(with: refusedIn)
        return account
    }

    /// Every outcome an item's write can come to, in two folders.
    private static let outcomes: [DragOutTally.Outcome] = [
        .landed(folder: "/a"), .landed(folder: "/b"),
        .failed(.refused, folder: "/a", promised: false), .failed(.refused, folder: "/a", promised: true),
        .failed(.refused, folder: "/b", promised: false), .failed(.unreadable, folder: "/a", promised: false),
        .failed(.unwritable, folder: "/b", promised: false), .failed(.unsupplied, folder: "/a", promised: true),
        .failed(.failed, folder: "/a", promised: false),
    ]

    /// Three items reach one folder holding a landed and a refused item while
    /// another folder's counts change; two items reach every replacement of
    /// an outcome by a second and a third.
    @Test(
        "every sequence of up to `depth` ends of `items` items' writes keeps the account counted from scratch",
        arguments: [(items: 2, depth: 4), (items: 3, depth: 3)])
    func incrementalMatchesScratch(items: Int, depth: Int) {
        let events = (0..<items).flatMap { index in Self.outcomes.map { (index, $0) } }
        var sequences: [[(Int, DragOutTally.Outcome)]] = [[]]
        for _ in 0..<depth {
            sequences = sequences.flatMap { sequence in events.map { sequence + [$0] } }
            for sequence in sequences {
                var tally = DragOutTally()
                var last: [Int: DragOutTally.Outcome] = [:]
                for (index, outcome) in sequence {
                    tally.record(outcome, at: index)
                    last[index] = outcome
                }
                let anyFailed = last.values.contains { if case .failed = $0 { true } else { false } }
                guard tally.account(items: items) == Self.account(of: last, items: items), tally.outcomes == last,
                    tally.ended == last.count, tally.hasFailures == anyFailed
                else {
                    Issue.record("the tally diverged after \(sequence)")
                    return
                }
            }
        }
    }
}
