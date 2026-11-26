import Foundation
import KernovaCommandModel
import KernovaKit

/// How the tool turns a typed snapshot argument into the snapshot it names.
///
/// Client-side, because the wire addresses a snapshot by identifier alone: the
/// listing every snapshot verb already reads is what a typed name is matched
/// against.
enum SnapshotResolution {
    /// The snapshot `text` names among `snapshots`, where `vm` is what the user
    /// called the virtual machine: the one whose identifier it spells, else
    /// the one whose name it is
    /// (``NameRule/sibling(identifiedOrNamedBy:in:id:name:)``). `forcingID`
    /// stops at the identifier reading, and refuses text that is not one
    /// rather than silently searching by name.
    ///
    /// - Throws: ``CLIFailure`` — ``CLIExitCode/usage`` for `forcingID` text
    ///   that is not an identifier, and ``CLIExitCode/notFound`` when nothing
    ///   matches.
    static func snapshot(
        named text: String, of vm: String, in snapshots: [SnapshotSummary], forcingID: Bool
    ) throws -> SnapshotSummary {
        guard forcingID else {
            guard let match = NameRule.sibling(identifiedOrNamedBy: text, in: snapshots, id: \.id, name: \.name)
            else { throw notFound(text, of: vm) }
            return match
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
}
