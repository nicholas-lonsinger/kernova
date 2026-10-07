import Foundation

/// What the config check window says about the files a check found it
/// cannot read.
struct ConfigCheckReport: Equatable {
    let files: [UnreadableConfigFile]
    /// The folder each file's path is written relative to; a file outside it
    /// is written in full.
    let libraryDirectory: URL?

    /// How many files Use Defaults rewrites.
    var repairableCount: Int { files.filter(\.isRepairable).count }

    var header: String {
        switch files.count {
        case 0: "Kernova read every config file."
        case 1: "Kernova can\u{2019}t read 1 config file."
        default: "Kernova can\u{2019}t read \(files.count) config files."
        }
    }

    /// One entry per file — its owner, its path, then a line per problem —
    /// with a blank line between entries.
    var body: String {
        files.map { file in
            ([file.owner.title, "  " + relativePath(of: file.url)]
                + file.problems.map { "  " + $0.reportLine(fileName: file.fileName) })
                .joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// What Use Defaults does, `nil` when there is nothing it can rewrite.
    var footer: String? {
        switch repairableCount {
        case 0:
            nil
        case 1:
            "Use Defaults rewrites the repairable file with these defaults; the original moves to the Trash."
        case let count:
            "Use Defaults rewrites the \(count) repairable files with these defaults; each original moves to the Trash."
        }
    }

    /// `url`'s path under ``libraryDirectory``, or in full when it is not under it.
    func relativePath(of url: URL) -> String {
        let path = VMBundleIdentity.spelling(url)
        guard let libraryDirectory else { return path }
        let base = VMBundleIdentity.spelling(libraryDirectory) + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// What Show in Finder selects: each file, or the folder a missing file
    /// would be in.
    var revealedURLs: [URL] {
        files.map { file in
            file.problems.contains { $0.issue == .fileMissing }
                ? file.url.deletingLastPathComponent() : file.url
        }
    }
}
