import Foundation
import KernovaKit

/// How the tool turns a typed snapshot argument into the snapshot it names.
///
/// Client-side, because the wire addresses a snapshot by identifier alone: the
/// listing every snapshot verb already reads is what a typed name is matched
/// against.
enum SnapshotResolution {
    /// The snapshot `text` names among `snapshots`, where `vm` is what the user
    /// called the virtual machine.
    ///
    /// Matched by ``SnapshotSelection``. `forcingID` stops at the identifier
    /// reading, and refuses text that is not one rather than silently
    /// searching by name.
    ///
    /// - Throws: ``CLIFailure`` — ``CLIExitCode/usage`` for `forcingID` text
    ///   that is not an identifier, ``CLIExitCode/notFound`` when nothing
    ///   matches, and ``CLIExitCode/ambiguous``, listing the candidates, when
    ///   more than one name does.
    static func snapshot(
        named text: String, of vm: String, in snapshots: [SnapshotSummary], forcingID: Bool
    ) throws -> SnapshotSummary {
        guard forcingID else {
            switch SnapshotSelection(text, in: snapshots, id: \.id, name: \.name) {
            case .found(let match): return match
            case .notFound: throw notFound(text, of: vm)
            case .ambiguous(let candidates): throw ambiguous(text, of: vm, candidates: candidates)
            }
        }
        guard let identifier = UUID(uuidString: text) else {
            throw CLIFailure(.usage, "\u{201C}\(text)\u{201D} is not a snapshot identifier.")
        }
        guard let match = snapshots.first(where: { $0.id == identifier }) else {
            throw notFound(text, of: vm)
        }
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
