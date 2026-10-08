import Foundation
import KernovaKit

// MARK: - The unreadable file

/// A config file Kernova can't read: where it is, whose it is, and every
/// problem a read of it met.
///
/// Thrown by every read of a library file the strict decode refuses, so no
/// reader can take an unreadable file for an empty one.
struct UnreadableConfigFile: LocalizedError, Sendable, Equatable {
    /// Whose settings the file holds, as the check names it.
    enum Owner: Sendable, Equatable {
        /// A VM, by the name its configuration gives it — or, where that
        /// cannot be read, by its bundle's folder name.
        case virtualMachine(String)
        case snapshot(vm: String, snapshot: String)
        case networkList
        case organization

        var title: String {
            switch self {
            case .virtualMachine(let name): name
            case .snapshot(let vm, let snapshot): "\(vm) \u{2014} snapshot \u{201C}\(snapshot)\u{201D}"
            case .networkList: "Network list"
            case .organization: "Smart groups, folders and tags"
            }
        }
    }

    /// Which file it is, by the write path it is repaired through.
    enum Location: Sendable, Hashable {
        /// A state file of the bundle at the URL.
        case bundle(URL, VMBundleStateFileID)
        /// The library's `Networks.json`.
        case networkList(URL)
        /// The library's `Organization.json`.
        case organization(URL)

        var url: URL {
            switch self {
            case .bundle(let bundleURL, let file): bundleURL.appendingPathComponent(file.relativePath)
            case .networkList(let url), .organization(let url): url
            }
        }
    }

    let location: Location
    let owner: Owner
    /// Never empty.
    let problems: [ConfigProblem]
    /// The bytes the problems were found in, `nil` when no bytes were read.
    /// A repair acts only while the file still holds these.
    let checkedDigest: ConfigFileDigest?

    init(
        location: Location, owner: Owner, problems: [ConfigProblem], checkedDigest: ConfigFileDigest? = nil
    ) {
        assert(!problems.isEmpty, "An unreadable file names at least one problem")
        self.location = location
        self.owner = owner
        self.problems = problems
        self.checkedDigest = checkedDigest
    }

    /// The file a strict decode that threw `strictFailure` refused, its bytes
    /// diagnosed as `diagnosis`. `owner` names it; `nil` takes the VM
    /// `$.name` names, else `fallbackName`.
    init(
        location: Location, owner: Owner?, fallbackName: String, diagnosis: ConfigFileDiagnosis,
        strictFailure: any Error
    ) {
        self.init(
            location: location,
            owner: owner ?? .virtualMachine(diagnosis.name ?? fallbackName),
            problems: diagnosis.problems.isEmpty
                ? [ConfigProblem(path: nil, issue: .other(reason: strictFailure.localizedDescription))]
                : diagnosis.problems,
            checkedDigest: diagnosis.digest)
    }

    var url: URL { location.url }

    var fileName: String { url.lastPathComponent }

    /// What the copy of the file a repair moves to the Trash is named:
    /// whose file it is, then the file's own name, so the Trash tells one
    /// `config.json` from another. The VM and snapshot names are shortened
    /// with an ellipsis so the whole name fits a path component's `NAME_MAX`
    /// (255) UTF-8 bytes.
    var trashedOriginalName: String {
        let separator = " \u{2014} "
        let budget = Self.maximumNameByteCount - separator.utf8.count - fileName.utf8.count
        let ownerPart: String
        switch owner {
        case .virtualMachine(let name):
            ownerPart = Self.shortened(name, toUTF8Bytes: budget)
        case .snapshot(let vm, let snapshot):
            let fixed = UnreadableConfigFile.Owner.snapshot(vm: "", snapshot: "").title.utf8.count
            let names = budget - fixed
            let vmPart = Self.shortened(vm, toUTF8Bytes: max(names / 2, names - snapshot.utf8.count))
            let snapshotPart = Self.shortened(snapshot, toUTF8Bytes: names - vmPart.utf8.count)
            ownerPart = UnreadableConfigFile.Owner.snapshot(vm: vmPart, snapshot: snapshotPart).title
        case .networkList, .organization:
            ownerPart = owner.title
        }
        // A slash cannot sit in a file name; the Finder shows a colon as one.
        // Both are one byte, so the swap keeps the bound.
        return "\(ownerPart)\(separator)\(fileName)".replacingOccurrences(of: "/", with: ":")
    }

    private static let maximumNameByteCount = 255

    /// `name` when it fits in `limit` UTF-8 bytes, else its longest leading
    /// run of whole characters that fits with an ellipsis after it.
    private static func shortened(_ name: String, toUTF8Bytes limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        let ellipsis = "\u{2026}"
        var kept = ""
        var byteCount = ellipsis.utf8.count
        for character in name {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= limit else { break }
            kept.append(character)
            byteCount += characterBytes
        }
        return kept + ellipsis
    }

    /// Whether Use Defaults rewrites it: every problem has a repair.
    var isRepairable: Bool { problems.allSatisfy(\.isRepairable) }

    /// The first problem, in one clause.
    var summary: String { problems[0].summary(fileName: fileName) }

    var errorDescription: String? {
        "\u{201C}\(fileName)\u{201D} could not be read: \(summary)."
    }
}
