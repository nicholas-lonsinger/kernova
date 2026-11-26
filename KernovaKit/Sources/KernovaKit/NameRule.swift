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

    /// What one class of sibling may be named, beyond the trimmed text more
    /// than whitespace every name is: nothing spelling one of its
    /// ``identifiers``, and, for a class whose names Kernova hands on to a
    /// file system, nothing holding a character it refuses, being a name it
    /// reserves, or running longer than it takes.
    public struct Shape: Sendable {
        /// What a door reads as one of these siblings' identifiers.
        public let identifiers: Identifiers
        private let refusedScalars: Set<Unicode.Scalar>
        private let reservedNames: Set<String>
        /// The most UTF-8 bytes a name holds, `nil` for no limit — enough for
        /// any first character and a count after it.
        private let maximumUTF8Length: Int?

        /// Names spelling none of `identifiers`, holding none of
        /// `refusedScalars` — which hold no whitespace and no digit, as a
        /// count does — none of `reservedNames`, and at most
        /// `maximumUTF8Length` bytes of UTF-8.
        public init(
            identifiers: Identifiers, refusing refusedScalars: Set<Unicode.Scalar> = [],
            reserving reservedNames: Set<String> = [], maximumUTF8Length: Int? = nil
        ) {
            self.identifiers = identifiers
            self.refusedScalars = refusedScalars
            self.reservedNames = reservedNames
            self.maximumUTF8Length = maximumUTF8Length
        }

        /// Names spelling no UUID: a virtual machine's, a network's, a
        /// group's, a snapshot's and a storage disk's.
        public static let uuid = Shape(identifiers: .uuid)

        /// Whether a trimmed name holding more than whitespace is one a
        /// sibling of this class may go by.
        fileprivate func admits(_ name: String) -> Bool {
            !identifiers.contains(name) && !reservedNames.contains(name)
                && !name.unicodeScalars.contains(where: refusedScalars.contains)
                && maximumUTF8Length.map { name.utf8.count <= $0 } ?? true
        }

        /// The name `text` makes for a sibling of this class: `text` without
        /// the characters the class refuses, trimmed, and cut to its longest —
        /// or `nil` where nothing is left, or what is left is a reserved name
        /// or spells an identifier.
        public func base(of text: String) -> String? {
            let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter { !refusedScalars.contains($0) }))
            let base = NameRule.trimmed(Self.prefix(of: NameRule.trimmed(kept), fitting: maximumUTF8Length))
            guard !base.isEmpty, admits(base) else { return nil }
            return base
        }

        /// `base`, a name ``base(of:)`` gives, counted `count`: "`base`
        /// `count`", `base` cut short where the whole would run longer than
        /// the class takes.
        fileprivate func counted(_ base: String, _ count: Int) -> String {
            let count = " \(count)"
            return Self.prefix(of: base, fitting: maximumUTF8Length.map { $0 - count.utf8.count }) + count
        }

        /// The longest run of `text`'s first scalars holding at most `limit`
        /// bytes of UTF-8 — cut between scalars, which keeps a first character
        /// that is one cluster of many.
        private static func prefix(of text: String, fitting limit: Int?) -> String {
            guard let limit, text.utf8.count > limit else { return text }
            var length = 0
            let kept = text.unicodeScalars.prefix { scalar in
                length += String(scalar).utf8.count
                return length <= limit
            }
            return String(String.UnicodeScalarView(kept))
        }
    }

    /// Why a name can't be given.
    public enum Refusal: Error, Equatable, Sendable {
        /// Nothing is left once whitespace and line breaks are trimmed.
        case empty
        /// The name spells an identifier, which text naming a sibling is read
        /// as first.
        case identifier(String)
        /// The name holds a character the class refuses, is a name it
        /// reserves, or runs longer than it takes (``Shape``).
        case disallowed(String)
        /// A sibling already goes by the name; the holder's name as it stands.
        case taken(by: String)

        /// This refusal in a sentence about a `noun`, such as "folder".
        public func sentence(about noun: String) -> String {
            switch self {
            case .empty:
                "A \(noun) needs a name."
            case .identifier(let name):
                "\u{201C}\(name)\u{201D} has the form of an identifier, which a \(noun)\u{2019}s name can\u{2019}t have."
            case .disallowed(let name):
                "\u{201C}\(name)\u{201D} can\u{2019}t name a \(noun)."
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
    /// sibling of `siblings`, whose class `shape` describes; throws why it
    /// can't be one.
    public static func validated(
        _ proposed: String, among siblings: some Sequence<String>, shape: Shape = .uuid
    ) throws(Refusal) -> String {
        let name = trimmed(proposed)
        guard !name.isEmpty else { throw .empty }
        guard !shape.identifiers.contains(name) else { throw .identifier(name) }
        guard shape.admits(name) else { throw .disallowed(name) }
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

    /// ``firstAvailable(_:among:)`` with what is taken asked of `isTaken`,
    /// each count cut to fit `shape` (``Shape/counted(_:_:)``).
    private static func firstAvailable(_ base: String, shape: Shape = .uuid, isTaken: (String) -> Bool) -> String {
        guard isTaken(base) else { return base }
        var counter = 2
        while isTaken(shape.counted(base, counter)) {
            counter += 1
        }
        return shape.counted(base, counter)
    }

    /// The name each of `stored` goes by, in the order given, as siblings
    /// whose class `shape` describes: a stored name that is well formed and
    /// one name with none already given keeps it, and every other takes the
    /// first well-formed name (``firstAvailable(_:among:)``), counted from the
    /// name its own makes (``Shape/base(of:)``) — or, where that makes none,
    /// from the one `fallback` of its index makes, else `fallback` itself —
    /// that is one name with no stored name and none already given.
    ///
    /// Every name it answers is well formed, and no two are one name
    /// (``isOneName(_:_:)``). Counting against the stored names leaves each
    /// later sibling's own name for it, so a set of well-formed names no two
    /// of which are one name comes back as it is. Each fallback makes a name,
    /// or becomes well formed with a count after it.
    public static func assignment(
        of stored: [String], shape: Shape = .uuid, fallback: (_ index: Int) -> String
    ) -> [String] {
        let storedNames = Names(stored)
        var given = Names()
        return storedNames.members.enumerated().map { index, comparand in
            if isWellFormed(comparand.name, shape: shape), !given.contains(comparand) {
                given.insert(comparand)
                return comparand.name
            }
            let base = shape.base(of: comparand.name) ?? shape.base(of: fallback(index)) ?? fallback(index)
            let free = firstAvailable(base, shape: shape) { candidate in
                guard !shape.identifiers.contains(candidate) else { return true }
                let candidate = Comparand(candidate)
                return storedNames.contains(candidate) || given.contains(candidate)
            }
            given.insert(Comparand(free))
            return free
        }
    }

    /// The name a new sibling asking for `proposed` goes by beside
    /// `siblings`, which ``assignment(of:shape:fallback:)`` gave: `proposed`,
    /// where it is well formed and free, else the first free name from the
    /// name it makes, or from `fallback` where it makes none.
    public static func name(
        for proposed: String, fallback: String, among siblings: [String], shape: Shape = .uuid
    ) -> String {
        assignment(of: siblings + [proposed], shape: shape) { _ in fallback }[siblings.count]
    }

    // MARK: - Names Kernova lists

    /// The name each item of a list is listed under, for items whose own
    /// names Kernova does not give — a USB accessory's, which the device
    /// reports — as siblings whose class `identifiers` identifies.
    ///
    /// An item whose own name, `names[i]`, is well formed and one name with no
    /// other item's is listed by it. Every other is listed as its name
    /// followed, in parentheses, by the first of `qualifiers[i]` — most human
    /// first — that leaves it well formed and one name with no other listed
    /// name, every item that would still read alike moving on to its next
    /// qualifier together. An item whose qualifiers all read alike to another's
    /// takes the first free name counted from its last, in the order of those
    /// names and qualifiers.
    ///
    /// A function of the set: an item is listed by the same name whatever
    /// order the items come in, and none by its place among them. No two names
    /// it answers are one name, and none spells an identifier.
    public static func listing(of names: [String], qualifiers: [[String]], identifiers: Identifiers) -> [String] {
        let items = names.indices
        let shape = Shape(identifiers: identifiers)
        /// Whether some other item's name in `listed` is one name with `item`'s.
        func readsAlike(_ item: Int, in listed: [Comparand]) -> Bool {
            items.contains {
                $0 != item && (listed[item].key == listed[$0].key || listed[item].isRelatedByCocoa(to: listed[$0]))
            }
        }
        let own = names.map(Comparand.init)
        let keeps = items.map { isWellFormed(names[$0], shape: shape) && !readsAlike($0, in: own) }
        var level = items.map { keeps[$0] || qualifiers[$0].isEmpty ? 0 : 1 }
        func listed(_ item: Int) -> String {
            level[item] == 0 ? names[item] : "\(names[item]) (\(qualifiers[item][level[item] - 1]))"
        }
        while true {
            let current = items.map(listed)
            let compared = current.map(Comparand.init)
            let clashing = items.filter { item in
                !keeps[item]
                    && (!isWellFormed(current[item], shape: shape) || readsAlike(item, in: compared))
            }
            let advancing = clashing.filter { level[$0] < qualifiers[$0].count }
            guard advancing.isEmpty else {
                for item in advancing { level[item] += 1 }
                continue
            }
            var given = Names(items.filter { !clashing.contains($0) }.map { current[$0] })
            var listing = current
            let ordered = clashing.sorted {
                (current[$0], qualifiers[$0].last ?? "") < (current[$1], qualifiers[$1].last ?? "")
            }
            for item in ordered {
                let free = firstAvailable(current[item]) { candidate in
                    identifiers.contains(candidate) || given.contains(Comparand(candidate))
                }
                given.insert(Comparand(free))
                listing[item] = free
            }
            return listing
        }
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

    /// Whether `name` is one a sibling whose class `shape` describes may go
    /// by, whoever else does: trimmed, holding more than whitespace, and one
    /// the shape admits.
    public static func isWellFormed(_ name: String, shape: Shape = .uuid) -> Bool {
        !name.isEmpty && name == trimmed(name) && shape.admits(name)
    }

    /// `name` without the whitespace and line breaks around it, as every name
    /// is given.
    public static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
