import Foundation

/// The one rule for a name Kernova owns among its siblings — a virtual
/// machine's in its library, a network's, a smart group's, a folder's, a
/// tag's, and a snapshot's, a storage disk's or a shared directory's in its
/// virtual machine: what a name may be, when two names are one name, which
/// sibling typed text names, and the first free name.
///
/// Typed text names a sibling as Cocoa Scripting finds an element by name:
/// the first whose name `caseInsensitiveCompare(_:)` finds the same as the
/// text, the name receiving it (``text(_:names:)``), so a name alone and a
/// range's named end are one function over one list. Two names are one name
/// when that comparison finds either the same as the other, or when they
/// fold to one key (``isOneName(_:_:)``), so no sibling's name is found the
/// same as another's. The comparison is not transitive, so that alone does
/// not keep typed text from being found the same as two siblings' names.
public enum NameRule {
    /// A name folded for case and compared by canonical equivalence.
    ///
    /// Two names whose keys are equal are one name even where
    /// `caseInsensitiveCompare(_:)` relates them neither way, as it does not
    /// `"\u{1E921}"` and `"\u{1E943}"`, one Adlam letter in its two cases.
    /// Keys that differ decide nothing: that comparison finds
    /// `"\u{1FCC}\u{0342}"` and `"\u{1FC7}"` each the same as the other, and
    /// they fold to two keys.
    private struct Key: Hashable {
        private let folded: String

        init(_ name: String) {
            folded = name.folding(options: .caseInsensitive, locale: nil)
        }
    }

    /// The text a door reads as one sibling's identifier rather than as a
    /// name, for one class of sibling — so no sibling of that class is named
    /// with it.
    public struct Identifiers: Sendable {
        private let spell: @Sendable (String) -> Bool

        /// The identifiers `spell` answers true for.
        public init(_ spell: @escaping @Sendable (String) -> Bool) {
            self.spell = spell
        }

        /// A UUID, in either case: how a virtual machine, a network, a group,
        /// a snapshot and a storage disk are identified.
        public static let uuid = Identifiers { UUID(uuidString: $0) != nil }

        /// Whether `text` spells one of these identifiers.
        public func contains(_ text: String) -> Bool {
            spell(text)
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

    // MARK: - Sameness

    /// Whether `lhs` and `rhs` are one name: `caseInsensitiveCompare(_:)`
    /// finds either the same as the other, or they fold to one key.
    ///
    /// Not an equivalence — that comparison is neither symmetric nor
    /// transitive — so a name is checked against every sibling.
    public static func isOneName(_ lhs: String, _ rhs: String) -> Bool {
        Names([lhs]).contains(Comparand(rhs))
    }

    /// A name made ready to be compared many times.
    private struct Comparand {
        let name: String
        let key: Key
        /// The name as one string object, compared without bridging it again.
        let compared: NSString

        init(_ name: String) {
            self.name = name
            key = Key(name)
            compared = NSString(string: name)
        }

        /// Whether `caseInsensitiveCompare(_:)` finds either of the two the
        /// same as the other.
        func isRelatedByCocoa(to other: Comparand) -> Bool {
            // NSString's own call, not `CFStringCompare` with
            // `.compareCaseInsensitive`, which answers otherwise:
            // "\u{1FCC}\u{0342}" and "\u{1FC7}" unequal both ways, where
            // `caseInsensitiveCompare(_:)` and `scriptingIsEqual(to:)` find
            // them the same (macOS 27.2.1).
            compared.caseInsensitiveCompare(other.compared as String) == .orderedSame
                || other.compared.caseInsensitiveCompare(compared as String) == .orderedSame
        }
    }

    /// Names a candidate is checked against, each compared at most once per
    /// check.
    private struct Names {
        private var keys = Set<Key>()
        private(set) var members: [Comparand] = []

        init(_ names: [String] = []) {
            for name in names { insert(Comparand(name)) }
        }

        mutating func insert(_ name: Comparand) {
            keys.insert(name.key)
            members.append(name)
        }

        /// The member `candidate` is one name with, if any.
        func member(sameAs candidate: Comparand) -> Comparand? {
            if keys.contains(candidate.key) { return members.first { $0.key == candidate.key } }
            // Every member's key differs from the candidate's here.
            return members.first { candidate.isRelatedByCocoa(to: $0) }
        }

        func contains(_ candidate: Comparand) -> Bool {
            member(sameAs: candidate) != nil
        }
    }

    // MARK: - Names a caller chooses

    /// `proposed` trimmed of whitespace and line breaks, as the name of a
    /// sibling of `siblings`, whose class `identifiers` identifies; throws why
    /// it can't be one.
    public static func validated(
        _ proposed: String, among siblings: some Sequence<String>, identifiers: Identifiers = .uuid
    ) throws(Refusal) -> String {
        let name = trimmed(proposed)
        guard !name.isEmpty else { throw .empty }
        guard !identifiers.contains(name) else { throw .identifier(name) }
        if let holder = Names(Array(siblings)).member(sameAs: Comparand(name)) { throw .taken(by: holder.name) }
        return name
    }

    // MARK: - Names Kernova picks

    /// `base` when it is one name with none of `taken`, else the first of
    /// "`base` 2", "`base` 3", … that is — counted after the whole of `base`,
    /// dots included.
    public static func firstAvailable(_ base: String, among taken: some Sequence<String>) -> String {
        let taken = Names(Array(taken))
        return firstAvailable(base) { taken.contains(Comparand($0)) }
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

    /// The name each of `stored` goes by, in the order given, as siblings
    /// whose class `identifiers` identifies: a stored name that is well formed
    /// and one name with none already given keeps it, and every other takes
    /// the first well-formed name (``firstAvailable(_:among:)``), counted from
    /// its trimmed self — or from `fallback` of its index where that is empty
    /// or spells an identifier — that is one name with no stored name and none
    /// already given.
    ///
    /// Every name it answers is well formed, and no two are one name
    /// (``isOneName(_:_:)``). Counting against the stored names leaves each
    /// later sibling's own name for it, so a set of well-formed names no two
    /// of which are one name comes back as it is. Each fallback is well
    /// formed, or becomes so with a count after it.
    public static func assignment(
        of stored: [String], identifiers: Identifiers = .uuid, fallback: (_ index: Int) -> String
    ) -> [String] {
        let storedNames = Names(stored)
        var given = Names()
        return storedNames.members.enumerated().map { index, comparand in
            if isWellFormed(comparand.name, identifiers: identifiers), !given.contains(comparand) {
                given.insert(comparand)
                return comparand.name
            }
            let own = trimmed(comparand.name)
            let base = own.isEmpty || identifiers.contains(own) ? fallback(index) : own
            let free = firstAvailable(base) { candidate in
                guard !identifiers.contains(candidate) else { return true }
                let candidate = Comparand(candidate)
                return storedNames.contains(candidate) || given.contains(candidate)
            }
            given.insert(Comparand(free))
            return free
        }
    }

    /// The name a new sibling asking for `proposed` goes by beside
    /// `siblings`, which ``assignment(of:identifiers:fallback:)`` gave:
    /// `proposed`, where it is well formed and free, else the first free name
    /// from it, or from `fallback` where it is empty or spells an identifier.
    public static func name(
        for proposed: String, fallback: String, among siblings: [String], identifiers: Identifiers = .uuid
    ) -> String {
        assignment(of: siblings + [proposed], identifiers: identifiers) { _ in fallback }[siblings.count]
    }

    // MARK: - Typed text

    /// Whether `text`, as typed, names `name`: `name.caseInsensitiveCompare(text)`,
    /// the call Cocoa Scripting makes of each element's name to find one by
    /// name.
    public static func text(_ text: String, names name: String) -> Bool {
        (name as NSString).caseInsensitiveCompare(text) == .orderedSame
    }

    /// The first of `siblings` that `text`, as typed, names (``text(_:names:)``),
    /// in their order — the one Cocoa Scripting finds.
    public static func sibling<Sibling>(
        named text: String, in siblings: [Sibling], name: (Sibling) -> String
    ) -> Sibling? {
        siblings.first { Self.text(text, names: name($0)) }
    }

    /// The sibling `text`, as typed, names among `siblings`: the one whose
    /// identifier it spells, or else the first it names by name.
    public static func sibling<Sibling>(
        identifiedOrNamedBy text: String, in siblings: [Sibling], id: (Sibling) -> UUID,
        name: (Sibling) -> String
    ) -> Sibling? {
        let identifier = UUID(uuidString: text)
        return sibling(
            identifiedBy: { identifier != nil && id($0) == identifier }, orNamedBy: text, in: siblings, name: name)
    }

    /// The sibling `text`, as typed, names among `siblings`: the first
    /// `identifies` answers true for — the one whose identifier `text`
    /// spells — or else the first it names by name.
    ///
    /// No sibling's name spells an identifier, so text that is one sibling's
    /// identifier is no sibling's name.
    public static func sibling<Sibling>(
        identifiedBy identifies: (Sibling) -> Bool, orNamedBy text: String, in siblings: [Sibling],
        name: (Sibling) -> String
    ) -> Sibling? {
        siblings.first(where: identifies) ?? sibling(named: text, in: siblings, name: name)
    }

    // MARK: - Shape

    /// Whether `name` is one a sibling whose class `identifiers` identifies
    /// may go by, whoever else does: trimmed, holding more than whitespace,
    /// and spelling no identifier.
    public static func isWellFormed(_ name: String, identifiers: Identifiers = .uuid) -> Bool {
        !name.isEmpty && name == trimmed(name) && !identifiers.contains(name)
    }

    /// `name` without the whitespace and line breaks around it, as every name
    /// is given.
    public static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
