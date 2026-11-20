import DeadCodeKit

extension PlatformBundle {
    /// The bundle of a platform's two scans, its production view less every finding at `DebugOnlyCode`, read from the
    /// sources the scanned build compiled: `source` returns the text of a repository-relative path.
    package init(
        full: [Finding], production: [Finding], presence: Presence, source: (String) throws -> String
    ) throws {
        var files: [String: DebugOnlyCode] = [:]
        let release = try production.filter { finding in
            let path = finding.location.path
            let code = try files[path] ?? DebugOnlyCode(path: path, source: source(path))
            files[path] = code
            return !code.contains(line: finding.location.line, column: finding.location.column)
        }
        self.init(full: full, production: release, presence: presence)
    }
}
