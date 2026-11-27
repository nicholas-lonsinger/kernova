import KernovaKit
import KernovaTransferProgress

/// Why one dragged item's write failed, when the failure is the item's own and the drag's other writes go on.
package enum DragOutItemFailure: Equatable, Sendable {
    /// This Mac did not permit the write (`EPERM`) where the item was dropped.
    case refused
    /// The VM could not read the item.
    case unreadable
    /// The item's bytes arrived but could not be written on this Mac.
    case unwritable
    /// An app in the VM never supplied the item.
    case unsupplied
    /// Any other failure of the item's own.
    case failed
}

/// What each of a drag out's items came to as its write ended, and the ``DragOutAccount`` of them all, which
/// each item's end changes in constant time.
struct DragOutTally {
    /// What one item's write came to.
    enum Outcome: Equatable {
        /// Written where it was dropped, in `folder`.
        case landed(folder: String)
        /// Failed as `failure` where it was dropped, in `folder`; `promised` when the item is a promise.
        case failed(DragOutItemFailure, folder: String, promised: Bool)
    }

    /// Each ended item's outcome, by index: an item is landed or failed, never both.
    private(set) var outcomes: [Int: Outcome] = [:]
    private var counts = DragOutAccount(items: 0)
    /// How many items landed in each folder.
    private var landedIn: [String: Int] = [:]
    /// How many items were refused in each folder.
    private var refusedIn: [String: Int] = [:]
    /// How many folders hold both a landed item and a refused one.
    private var foldersLandedAndRefused = 0
    /// How many refused items are promises.
    private var refusedPromises = 0

    /// Records that item `index` came to `outcome`, in place of any outcome it came to before.
    mutating func record(_ outcome: Outcome, at index: Int) {
        if let previous = outcomes.updateValue(outcome, forKey: index) { count(previous, by: -1) }
        count(outcome, by: 1)
    }

    /// Whether item `index`'s write has ended.
    func hasEnded(_ index: Int) -> Bool { outcomes[index] != nil }

    /// How many items' writes have ended.
    var ended: Int { outcomes.count }

    /// Whether any item's write failed.
    var hasFailures: Bool { counts.landed < outcomes.count }

    /// The account of a drag of `items` items.
    func account(items: Int) -> DragOutAccount {
        var account = counts
        account.items = items
        account.refusedBesideLanded = foldersLandedAndRefused > 0
        account.refusedPromise = refusedPromises > 0
        return account
    }

    private mutating func count(_ outcome: Outcome, by delta: Int) {
        switch outcome {
        case .landed(let folder):
            counts.landed += delta
            countFolder(folder, landed: delta, refused: 0)
        case .failed(.refused, let folder, let promised):
            counts.refused += delta
            if promised { refusedPromises += delta }
            countFolder(folder, landed: 0, refused: delta)
        case .failed(.unreadable, _, _): counts.unreadable += delta
        case .failed(.unwritable, _, _): counts.unwritable += delta
        case .failed(.unsupplied, _, _): counts.unsupplied += delta
        case .failed(.failed, _, _): counts.failed += delta
        }
    }

    private mutating func countFolder(_ folder: String, landed: Int, refused: Int) {
        let before = (landedIn[folder, default: 0], refusedIn[folder, default: 0])
        let after = (before.0 + landed, before.1 + refused)
        landedIn[folder] = after.0 == 0 ? nil : after.0
        refusedIn[folder] = after.1 == 0 ? nil : after.1
        let held = before.0 > 0 && before.1 > 0
        let holds = after.0 > 0 && after.1 > 0
        if held != holds { foldersLandedAndRefused += holds ? 1 : -1 }
    }
}
