import Foundation

/// The one rule for a name Kernova owns among its siblings — a virtual
/// machine's in its library, a network's, a smart group's, a folder's, a
/// tag's: what a name may be, when two names are one name, which sibling typed
/// text names, and the first free name.
public enum NameRule {
    /// A name as sameness reads it: two names are one name exactly when their
    /// keys are equal, which makes sameness an equivalence.
    ///
    /// `caseInsensitiveCompare(_:)`, by which Cocoa Scripting resolves a
    /// range's named end, is not one: it finds `"\u{1F08}\u{0399}"` the same as
    /// `"\u{1F80}"` and not the reverse. Both fold to one key, so no typed text
    /// that comparison matches to two names can reach two siblings.
    public struct Key: Hashable, Sendable {
        private let folded: String

        public init(_ name: String) {
            folded = name.folding(options: .caseInsensitive, locale: nil)
        }
    }

    /// Why a name can't be given.
    public enum Refusal: Error, Equatable, Sendable {
        /// Nothing is left once whitespace and line breaks are trimmed.
        case empty
        /// The name spells an identifier, which text naming a sibling is read
        /// as first.
        case identifier(String)
        /// A sibling already goes by the name; the holder's name as it stands.
        case taken(by: String)

        /// This refusal in a sentence about a `noun`, such as "folder".
        public func sentence(about noun: String) -> String {
            switch self {
            case .empty:
                "A \(noun) needs a name."
            case .identifier(let name):
                "\u{201C}\(name)\u{201D} can\u{2019}t name a \(noun): an identifier already names one."
            case .taken(let holder):
                "A \(noun) named \u{201C}\(holder)\u{201D} already exists. Give this one another name."
            }
        }
    }

    // MARK: - Names a caller chooses

    /// `proposed` trimmed of whitespace and line breaks, as the name of a
    /// sibling of `siblings`; throws why it can't be one.
    public static func validated(
        _ proposed: String, among siblings: some Sequence<String>
    ) throws(Refusal) -> String {
        let name = trimmed(proposed)
        guard !name.isEmpty else { throw .empty }
        guard UUID(uuidString: name) == nil else { throw .identifier(name) }
        let key = Key(name)
        if let holder = siblings.first(where: { Key($0) == key }) { throw .taken(by: holder) }
        return name
    }

    // MARK: - Names Kernova picks

    /// `base` when no name of `taken` is it, else the first of "`base` 2",
    /// "`base` 3", … none is — counted after the whole of `base`, dots
    /// included.
    public static func firstAvailable(_ base: String, among taken: some Sequence<String>) -> String {
        let keys = Set(taken.map(Key.init))
        return firstAvailable(base) { keys.contains(Key($0)) }
    }

    /// ``firstAvailable(_:among:)`` with what is taken asked of `isTaken`.
    private static func firstAvailable(_ base: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(base) else { return base }
        var counter = 2
        while isTaken("\(base) \(counter)") {
            counter += 1
        }
        return "\(base) \(counter)"
    }

    /// The name each of `stored` goes by, in the order given: a stored name
    /// that is well formed and that no earlier one took keeps it, and every
    /// other takes the first well-formed name free (``firstAvailable(_:among:)``)
    /// from its trimmed self, or from `fallback` when that leaves nothing —
    /// counted against every stored name and every name already given.
    ///
    /// Every name it answers is well formed, and no two are one name. Counting
    /// against the stored names leaves each later sibling's own name for it,
    /// so a set whose names are already well formed and distinct comes back
    /// as it is. `fallback` is well formed.
    public static func assignment(of stored: [String], fallback: String) -> [String] {
        let storedKeys = Set(stored.map(Key.init))
        var given = Set<Key>()
        return stored.map { name in
            if isWellFormed(name), given.insert(Key(name)).inserted { return name }
            let base = trimmed(name).isEmpty ? fallback : trimmed(name)
            let free = firstAvailable(base) { candidate in
                let key = Key(candidate)
                return UUID(uuidString: candidate) != nil || storedKeys.contains(key) || given.contains(key)
            }
            given.insert(Key(free))
            return free
        }
    }

    /// The name a new sibling asking for `proposed` goes by beside
    /// `siblings`, which ``assignment(of:fallback:)`` gave: `proposed`, where
    /// it is well formed and free, else the first free name from it.
    public static func name(
        for proposed: String, fallback: String, among siblings: [String]
    ) -> String {
        assignment(of: siblings + [proposed], fallback: fallback)[siblings.count]
    }

    // MARK: - Typed text

    /// Whether `text`, as typed, is `name`.
    public static func text(_ text: String, names name: String) -> Bool {
        Key(text) == Key(name)
    }

    /// The sibling among `siblings` that `text`, as typed, names: the one it
    /// is the name of (``text(_:names:)``).
    ///
    /// The first, where several share the name — siblings whose names are not
    /// held to this rule.
    public static func sibling<Sibling>(
        named text: String, in siblings: [Sibling], name: (Sibling) -> String
    ) -> Sibling? {
        let key = Key(text)
        return siblings.first { Key(name($0)) == key }
    }

    /// The sibling `text`, as typed, names among `siblings`: the one whose
    /// identifier it spells, or else the one it is the name of.
    public static func sibling<Sibling>(
        identifiedOrNamedBy text: String, in siblings: [Sibling], id: (Sibling) -> UUID,
        name: (Sibling) -> String
    ) -> Sibling? {
        if let identifier = UUID(uuidString: text), let match = siblings.first(where: { id($0) == identifier }) {
            return match
        }
        return sibling(named: text, in: siblings, name: name)
    }

    // MARK: - Shape

    /// Whether `name` is one a sibling may go by, whoever else does: trimmed,
    /// holding more than whitespace, and spelling no identifier.
    public static func isWellFormed(_ name: String) -> Bool {
        !name.isEmpty && name == trimmed(name) && UUID(uuidString: name) == nil
    }

    /// `name` without the whitespace and line breaks around it, as every name
    /// is given.
    public static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
