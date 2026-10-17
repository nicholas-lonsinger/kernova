import AppIntents
import Foundation
import KernovaKit

/// The mode every VM on a named network runs in, offered as a Shortcuts
/// picker.
///
/// Mirrors ``NetworkKind`` rather than conforming it, for the reason
/// ``VMStopMethod`` gives. ``init(_:)`` is exhaustive over the kinds, so a new
/// one fails to build here rather than reaching Shortcuts unnamed.
enum VMNetworkKind: String, AppEnum {
    case nat
    case hostOnly

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Network Kind")

    static let caseDisplayRepresentations: [VMNetworkKind: DisplayRepresentation] = [
        .nat: "NAT",
        .hostOnly: "Host Only",
    ]

    /// The kind this case names.
    var kind: NetworkKind {
        switch self {
        case .nat: .nat
        case .hostOnly: .hostOnly
        }
    }

    /// The case naming `kind`.
    init(_ kind: NetworkKind) {
        self =
            switch kind {
            case .nat: .nat
            case .hostOnly: .hostOnly
            }
    }
}
