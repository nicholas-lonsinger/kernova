import Foundation

/// What one platform's index compiled: every declaration site and every line holding a module reference, keyed as
/// findings are (`Finding.key`), so a platform that compiled a reported declaration without reporting it is known
/// to use it.
package struct Presence: Equatable, Sendable {
    package var keys: Set<FindingKey>

    package init(keys: Set<FindingKey> = []) {
        self.keys = keys
    }

    package func contains(_ key: FindingKey) -> Bool {
        keys.contains(key)
    }

    /// One row per key, sorted: `D path line column` for a declaration, `I path line module` for an import, tab-separated.
    package var tsv: String {
        keys.sorted().map { key in
            switch key {
            case .declaration(let path, let line, let column): "D\t\(path)\t\(line)\t\(column)\n"
            case .importStatement(let path, let line, let module): "I\t\(path)\t\(line)\t\(module)\n"
            }
        }.joined()
    }

    package init(tsv: String) throws(PresenceError) {
        var keys = Set<FindingKey>()
        for (offset, row) in tsv.split(separator: "\n").enumerated() {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4, let line = Int(fields[2]) else { throw .malformedRow(offset + 1) }
            switch fields[0] {
            case "D":
                guard let column = Int(fields[3]) else { throw .malformedRow(offset + 1) }
                keys.insert(.declaration(path: String(fields[1]), line: line, column: column))
            case "I":
                keys.insert(.importStatement(path: String(fields[1]), line: line, module: String(fields[3])))
            default:
                throw .malformedRow(offset + 1)
            }
        }
        self.init(keys: keys)
    }
}

package enum PresenceError: Error, Equatable, CustomStringConvertible {
    case malformedRow(Int)

    package var description: String {
        switch self {
        case .malformedRow(let row): "presence row \(row) is not 'D|I<TAB>path<TAB>line<TAB>column|module'"
        }
    }
}

/// Reduces `indexutil-export tsv`'s occurrences stream — `usr role path line column`, one role per row — to a
/// `Presence`, byte by byte, so the export never has to exist whole: a macOS scan's index exports to hundreds of
/// megabytes of rows, almost none of them a declaration in this repository.
///
/// A row is kept when its path lies under `root` outside a build directory (`.build/`, `DerivedData/`), and it is a
/// definition or declaration, or a reference to a module (`c:@M@<module>`).
package struct PresenceFilter {
    package private(set) var presence = Presence()
    private let root: [UInt8]
    private var pending: [UInt8] = []

    package init(root: String) {
        var root = root
        while root.hasSuffix("/") { root.removeLast() }
        self.root = Array((root + "/").utf8)
    }

    package mutating func consume(_ bytes: some Sequence<UInt8>) {
        pending.append(contentsOf: bytes)
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: Self.newline) {
            row(pending[start..<newline])
            start = newline + 1
        }
        pending.removeSubrange(..<start)
    }

    /// Reads a final row that has no newline after it.
    package mutating func finish() {
        if !pending.isEmpty { row(pending[...]) }
        pending.removeAll()
    }

    private mutating func row(_ row: ArraySlice<UInt8>) {
        var fields: [ArraySlice<UInt8>] = []
        fields.reserveCapacity(5)
        var start = row.startIndex
        for index in row.indices where row[index] == Self.tab {
            fields.append(row[start..<index])
            start = index + 1
        }
        fields.append(row[start...])
        guard fields.count == 5 else { return }
        let (usr, role, path, line, column) = (fields[0], fields[1], fields[2], fields[3], fields[4])

        let isDeclaration = role.elementsEqual(Self.definition) || role.elementsEqual(Self.declaration)
        let isModuleReference = role.elementsEqual(Self.reference) && usr.starts(with: Self.modulePrefix)
        guard isDeclaration || isModuleReference, path.starts(with: root) else { return }
        let relative = String(decoding: path.dropFirst(root.count), as: UTF8.self)
        guard !relative.hasPrefix("DerivedData/"), !relative.hasPrefix(".build/"), !relative.contains("/.build/"),
            let lineNumber = Int(String(decoding: line, as: UTF8.self))
        else { return }

        if isDeclaration {
            guard let columnNumber = Int(String(decoding: column, as: UTF8.self)) else { return }
            presence.keys.insert(.declaration(path: relative, line: lineNumber, column: columnNumber))
        } else {
            let module = String(decoding: usr.dropFirst(Self.modulePrefix.count), as: UTF8.self)
            presence.keys.insert(.importStatement(path: relative, line: lineNumber, module: module))
        }
    }

    private static let newline = UInt8(ascii: "\n")
    private static let tab = UInt8(ascii: "\t")
    private static let definition = Array("definition".utf8)
    private static let declaration = Array("declaration".utf8)
    private static let reference = Array("reference".utf8)
    private static let modulePrefix = Array("c:@M@".utf8)
}
