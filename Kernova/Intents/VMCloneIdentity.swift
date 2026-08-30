import AppIntents
import Foundation
import KernovaKit

/// What a clone does with the source VM's machine identity, offered as a
/// Shortcuts picker.
///
/// Mirrors ``CloneMachineIdentity`` rather than conforming it: the App Intents
/// metadata processor reads an `AppEnum`'s cases and case display
/// representations out of the declaring target's own source ("enums implemented
/// in an imported framework or library are not supported"), and
/// ``CloneMachineIdentity`` lives in KernovaKit, which the guest agent links and
/// so cannot import AppIntents. ``init(_:)`` is exhaustive over the identities,
/// so a new one fails to build here rather than reaching Shortcuts unnamed.
enum VMCloneIdentity: String, AppEnum {
    /// Follow the app's clone preference.
    case followPreference
    /// Mint a fresh identity, so both VMs can run at once.
    case new
    /// Keep the source's identity, so the clone is the same machine to its
    /// guest — and cannot run beside the source.
    case keep

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Machine Identity")

    static let caseDisplayRepresentations: [VMCloneIdentity: DisplayRepresentation] = [
        .followPreference: "Follow Kernova Setting",
        .new: "New Identity",
        .keep: "Same Identity",
    ]

    /// The identity this case names.
    var identity: CloneMachineIdentity {
        switch self {
        case .followPreference: .followPreference
        case .new: .new
        case .keep: .keep
        }
    }

    /// The case naming `identity`.
    init(_ identity: CloneMachineIdentity) {
        self =
            switch identity {
            case .followPreference: .followPreference
            case .new: .new
            case .keep: .keep
            }
    }
}
