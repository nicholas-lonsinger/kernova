import AppIntents
import Foundation
import KernovaKit

/// What a clone is of its source, offered as a Shortcuts picker.
///
/// Mirrors ``CloneOutcome`` rather than conforming it: the App Intents
/// metadata processor reads an `AppEnum`'s cases and case display
/// representations out of the declaring target's own source ("enums implemented
/// in an imported framework or library are not supported"), and
/// ``CloneOutcome`` lives in KernovaKit, which the guest agent links and so
/// cannot import AppIntents. ``init(_:)`` is exhaustive over the outcomes, so a
/// new one fails to build here rather than reaching Shortcuts unnamed.
enum VMCloneOutcome: String, AppEnum {
    case followPreference
    case newMachine
    case exactCopy

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Clone Outcome")

    static let caseDisplayRepresentations: [VMCloneOutcome: DisplayRepresentation] = [
        .followPreference: "Follow Kernova Setting",
        .newMachine: "New Machine",
        .exactCopy: "Exact Copy",
    ]

    /// The outcome this case asks for, `nil` following the app's preference.
    var outcome: CloneOutcome? {
        switch self {
        case .followPreference: nil
        case .newMachine: .newMachine
        case .exactCopy: .exactCopy
        }
    }

    /// The case asking for `outcome`.
    init(_ outcome: CloneOutcome?) {
        self =
            switch outcome {
            case nil: .followPreference
            case .newMachine: .newMachine
            case .exactCopy: .exactCopy
            }
    }
}
