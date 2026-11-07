import Foundation

/// One platform's scan as the combined report reads it: both views' findings and the presence of the index they came
/// from, written and read only together, so a bundle never pairs reports with another build's index.
package struct PlatformBundle: Equatable, Sendable {
    /// Every file a bundle directory holds.
    package static let files = ["full.json", "production.json", "presence.tsv"]

    /// The scan with test targets built.
    package var full: [Finding]
    /// The scan with every target only tests reach excluded.
    package var production: [Finding]
    /// The index both scans read.
    package var presence: Presence

    /// A bundle of the given views, each sorted so the same scan writes the same bytes.
    package init(full: [Finding], production: [Finding], presence: Presence) {
        func sorted(_ findings: [Finding]) -> [Finding] {
            findings.sorted { ($0.key, $0.name, $0.hints.description) < ($1.key, $1.name, $1.hints.description) }
        }
        self.full = sorted(full)
        self.production = sorted(production)
        self.presence = presence
    }

    /// Replaces `directory` with this bundle: every file is written beside it first, then the directory is swapped
    /// in whole, so no file of an earlier bundle survives.
    ///
    /// A directory holding anything other than a bundle's files is refused rather than replaced.
    package func write(to directory: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let foreign = try manager.contentsOfDirectory(atPath: directory.path)
                .filter { !Self.files.contains($0) }
            guard foreign.isEmpty else { throw BundleError.foreignFiles(directory.path, foreign.sorted()) }
        }
        let parent = directory.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(directory.lastPathComponent)-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(full).write(to: staging.appendingPathComponent("full.json"))
            try encoder.encode(production).write(to: staging.appendingPathComponent("production.json"))
            try Data(presence.tsv.utf8).write(to: staging.appendingPathComponent("presence.tsv"))
            if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
            try manager.moveItem(at: staging, to: directory)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// The bundle in `directory`, which must hold every one of its files.
    package init(contentsOf directory: URL) throws {
        func data(_ file: String) throws -> Data {
            let url = directory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw BundleError.missingFile(url.path)
            }
            return try Data(contentsOf: url)
        }
        let decoder = JSONDecoder()
        self.init(
            full: try decoder.decode([Finding].self, from: data("full.json")),
            production: try decoder.decode([Finding].self, from: data("production.json")),
            presence: try Presence(tsv: String(decoding: data("presence.tsv"), as: UTF8.self)))
    }
}

/// Why a bundle directory was not read or written.
package enum BundleError: Error, Equatable, CustomStringConvertible {
    case missingFile(String)
    case foreignFiles(String, [String])
    case noTestOnlyTargets
    case emptyStore(store: String, root: String)
    case unindexedTargets(store: String, targets: [String])

    package var description: String {
        switch self {
        case .missingFile(let path): "the bundle lacks \(path)"
        case .noTestOnlyTargets:
            "no target is listed as reached only by tests, so the production view would be the full one"
        case .emptyStore(let store, let root): "\(store) holds no declaration under \(root)"
        case .unindexedTargets(let store, let targets):
            "\(store) holds no declaration from " + targets.joined(separator: ", ")
                + ", so it is not the build of the package the scan reads"
        case .foreignFiles(let directory, let files):
            "\(directory) holds files no bundle writes, so it is not replaced: " + files.joined(separator: ", ")
        }
    }
}
