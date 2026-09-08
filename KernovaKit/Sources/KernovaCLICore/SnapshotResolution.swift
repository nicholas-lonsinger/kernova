import Foundation
import KernovaKit

/// How the tool turns a typed snapshot argument into the snapshot it names.
///
/// Client-side, because the wire addresses a snapshot by identifier alone: the
/// listing every snapshot verb already reads is what a typed name is matched
/// against, so the app needs no second way to name one.
enum SnapshotResolution {
    /// The snapshot `text` names among `snapshots`, where `vm` is what the user
    /// called the virtual machine.
    ///
    /// Text that parses as an identifier is matched against the identifiers
    /// first and falls back to the names, so a snapshot literally named after
    /// another's identifier is still reachable. `forcingID` stops at the
    /// identifier reading, and refuses text that is not one rather than
    /// silently searching by name.
    ///
    /// - Throws: ``CLIFailure`` — ``CLIExitCode/usage`` for `forcingID` text
    ///   that is not an identifier, ``CLIExitCode/notFound`` when nothing
    ///   matches, and ``CLIExitCode/ambiguous``, listing the candidates, when
    ///   more than one name does.
    static func snapshot(
        named text: String, of vm: String, in snapshots: [SnapshotSummary], forcingID: Bool
    ) throws -> SnapshotSummary {
        let identifier = UUID(uuidString: text)
        if let identifier, let match = snapshots.first(where: { $0.id == identifier }) {
            return match
        }
        guard !forcingID else {
            guard identifier != nil else {
                throw CLIFailure(.usage, "\u{201C}\(text)\u{201D} is not a snapshot identifier.")
            }
            throw notFound(text, of: vm)
        }
        let matching = snapshots.filter { $0.name == text }
        guard matching.count <= 1 else { throw ambiguous(text, of: vm, candidates: matching) }
        guard let match = matching.first else { throw notFound(text, of: vm) }
        return match
    }

    private static func notFound(_ text: String, of vm: String) -> CLIFailure {
        CLIFailure(
            .notFound,
            "No snapshot named \u{201C}\(text)\u{201D} on \u{201C}\(vm)\u{201D}.")
    }

    /// The candidates one per line: a name a script feeds back is on the line
    /// with the identifier that replaces it, however many there are.
    private static func ambiguous(
        _ text: String, of vm: String, candidates: [SnapshotSummary]
    ) -> CLIFailure {
        CLIFailure(
            .ambiguous,
            "\u{201C}\(text)\u{201D} names \(candidates.count) snapshots of "
                + "\u{201C}\(vm)\u{201D}. Use one of their identifiers instead:\n"
                + candidates.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: "\n"))
    }
}
