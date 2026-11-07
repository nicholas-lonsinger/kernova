import Foundation

/// A platform the combined scan covers. A report missing one of them is partial: what only that platform uses reads
/// as dead.
package enum Platform: String, CaseIterable, Comparable, Sendable {
    case macos
    case linux

    package var displayName: String {
        switch self {
        case .macos: "macOS"
        case .linux: "Linux"
        }
    }

    package static func < (lhs: Platform, rhs: Platform) -> Bool {
        lhs.order < rhs.order
    }

    private var order: Int {
        switch self {
        case .macos: 0
        case .linux: 1
        }
    }
}

/// One result of Periphery's `--format json` report, reduced to the fields the combined report reads.
package struct Finding: Codable, Hashable, Sendable {
    package var kind: String
    package var name: String
    package var hints: [String]
    package var location: FileLocation
    package var ids: [String]

    package init(kind: String, name: String, hints: [String], location: FileLocation, ids: [String]) {
        self.kind = kind
        self.name = name
        self.hints = hints
        self.location = location
        self.ids = ids
    }

    /// The place this finding is judged at on every platform.
    ///
    /// An import is keyed by its line and module, because Periphery reports it at column 1 and the index records the
    /// module reference at the module name. Everything else is keyed by its full location, never by USR: a declaration
    /// in `Foo+Darwin.swift` and its twin in `Foo+Linux.swift` share a USR and are separate code.
    package var key: FindingKey {
        if kind == "module" {
            return .importStatement(path: location.path, line: location.line, module: name)
        }
        return .declaration(path: location.path, line: location.line, column: location.column)
    }

    /// A protocol conformance Periphery lists after a `redundantProtocol` finding, at the conformance's reference.
    package var isConformance: Bool {
        hints.contains { $0.hasPrefix("redundantConformance") }
    }

    /// This finding with its location rewritten relative to `root`.
    ///
    /// A relative path is resolved against `base`, the directory Periphery ran in.
    package func normalized(root: String, base: String) throws(FindingError) -> Finding {
        let path = location.path
        let absolute = path.hasPrefix("/") ? path : base.trimmingSlash + "/" + path
        let prefix = root.trimmingSlash + "/"
        guard absolute.hasPrefix(prefix) else { throw .outsideRoot(path: absolute, root: root) }
        var copy = self
        copy.location.path = String(absolute.dropFirst(prefix.count))
        return copy
    }
}

package enum FindingError: Error, Equatable, CustomStringConvertible {
    case outsideRoot(path: String, root: String)

    package var description: String {
        switch self {
        case .outsideRoot(let path, let root): "a finding lies outside the repository root \(root): \(path)"
        }
    }
}

/// `path:line:column`, split from the right so a path may hold a colon; it codes as that string.
package struct FileLocation: Codable, Hashable, Sendable, CustomStringConvertible {
    package var path: String
    package var line: Int
    package var column: Int

    package init(path: String, line: Int, column: Int) {
        self.path = path
        self.line = line
        self.column = column
    }

    package init?(_ text: String) {
        guard let fields = text.reversedSplit(), let line = Int(fields.line), let column = Int(fields.column),
            !fields.path.isEmpty
        else {
            return nil
        }
        self.init(path: fields.path, line: line, column: column)
    }

    package var description: String { "\(path):\(line):\(column)" }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let location = FileLocation(text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "a location is not path:line:column: \(text)")
        }
        self = location
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Where a finding is judged, and where a platform's index records a declaration or an import.
package enum FindingKey: Hashable, Comparable, Sendable {
    case declaration(path: String, line: Int, column: Int)
    case importStatement(path: String, line: Int, module: String)

    package var path: String {
        switch self {
        case .declaration(let path, _, _), .importStatement(let path, _, _): path
        }
    }

    package var line: Int {
        switch self {
        case .declaration(_, let line, _), .importStatement(_, let line, _): line
        }
    }

    private var sortKey: (String, Int, Int, String) {
        switch self {
        case .declaration(let path, let line, let column): (path, line, column, "")
        case .importStatement(let path, let line, let module): (path, line, 0, module)
        }
    }

    package static func < (lhs: FindingKey, rhs: FindingKey) -> Bool {
        lhs.sortKey < rhs.sortKey
    }
}

extension String {
    fileprivate var trimmingSlash: String {
        var copy = self
        while copy.count > 1, copy.hasSuffix("/") { copy.removeLast() }
        return copy
    }

    /// `path`, `line` and `column` of `path:line:column`, split at the last two colons.
    fileprivate func reversedSplit() -> (path: String, line: Substring, column: Substring)? {
        guard let columnColon = lastIndex(of: ":") else { return nil }
        let head = self[..<columnColon]
        guard let lineColon = head.lastIndex(of: ":") else { return nil }
        return (String(head[..<lineColon]), head[index(after: lineColon)...], self[index(after: columnColon)...])
    }
}
