import AppIntents
import Foundation
import KernovaKit

/// How a stop reaches a guest, offered as a Shortcuts picker.
///
/// Mirrors ``StopDisposition`` rather than conforming it: the App Intents
/// metadata processor reads an `AppEnum`'s cases and case display
/// representations out of the declaring target's own source ("enums implemented
/// in an imported framework or library are not supported"), and
/// ``StopDisposition`` lives in KernovaKit, which the guest agent links and so
/// cannot import AppIntents. ``init(_:)`` is exhaustive over the dispositions,
/// so a new one fails to build here rather than reaching Shortcuts unnamed.
enum VMStopMethod: String, AppEnum {
    /// Request an ACPI shutdown and let the guest power itself off.
    case shutDown
    /// Resume a paused guest first, then request the shutdown it cannot receive
    /// while paused.
    case resumeThenShutDown
    /// Terminate the virtual machine immediately, losing unsaved guest state.
    case force

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Stop Method")

    static let caseDisplayRepresentations: [VMStopMethod: DisplayRepresentation] = [
        .shutDown: "Shut Down",
        .resumeThenShutDown: "Resume and Shut Down",
        .force: "Force Stop",
    ]

    /// The disposition this method names.
    var disposition: StopDisposition {
        switch self {
        case .shutDown: .graceful
        case .resumeThenShutDown: .resumeThenShutDown
        case .force: .force
        }
    }

    /// The method naming `disposition`.
    init(_ disposition: StopDisposition) {
        self =
            switch disposition {
            case .graceful: .shutDown
            case .resumeThenShutDown: .resumeThenShutDown
            case .force: .force
            }
    }
}
