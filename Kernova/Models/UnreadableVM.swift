import Foundation

/// A bundle in the VMs directory whose files Kernova can't read, kept in the
/// library as a row of its own so it stays in sight with its way out.
///
/// It is no ``VMInstance``, so no VM verb, capability or menu command can
/// address it: what it offers is the config check, Show in Finder, and a move
/// of the whole bundle to the Trash.
@MainActor
final class UnreadableVM {
    /// Fixed by where the bundle is, so a re-read keeps the row's place and
    /// selection.
    let id: UUID
    let bundleURL: URL
    /// The file that kept the bundle out, as the read found it.
    let file: UnreadableConfigFile

    init(_ bundle: UnreadableBundle) {
        self.id = Self.id(for: bundle.url)
        self.bundleURL = bundle.url
        self.file = bundle.file
    }

    /// The row identifier of the bundle at `bundleURL`.
    static func id(for bundleURL: URL) -> UUID {
        StableID.uuid(seed: "unreadable-bundle\u{0}\(VMBundleIdentity.nameKey(bundleURL))")
    }

    /// The VM's name where its configuration gives one, else its bundle's
    /// folder name.
    var name: String { file.owner.title }

    /// What the row reads as where a VM's row states its status.
    static let statusText = "Can\u{2019}t Be Read"

    /// Why the row is unreadable, and where to go about it.
    var toolTip: String {
        "Kernova can\u{2019}t read this virtual machine\u{2019}s settings: \(file.summary). "
            + "Choose File > Check Config Files\u{2026} to review it."
    }
}

/// A bundle a read could not take, as it crosses back from the reading task.
struct UnreadableBundle: Sendable, Equatable {
    let url: URL
    let file: UnreadableConfigFile
}
