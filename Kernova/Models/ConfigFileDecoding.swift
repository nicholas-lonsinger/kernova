import CryptoKit
import Foundation
import Synchronization

// MARK: - Config fields

/// Every config field that a file can hold a value the field does not take
/// decodes through one of these, chosen by what the field says:
///
/// | Field | Absent | Unrecognized, strict | Unrecognized, collecting |
/// |---|---|---|---|
/// | A preference (`default:`) | the default | throws | repaired to the default |
/// | A list of entries (`default:` on an array) | the default | throws | each bad entry removed |
/// | A fact (`absentMeans:`) | the stated value | throws | recorded, unrepairable |
/// | Required, repairable (`repairingTo:`) | throws; collecting repairs | throws | repaired to the default |
///
/// A preference is a choice the user or the app made, which a new instance
/// makes for itself; a fact records what exists on disk or what happened,
/// which no default can stand in for.
extension KeyedDecodingContainer {
    /// A preference: the value at `key`, or `defaultValue` — the value a new
    /// instance gets — when the file holds none there.
    ///
    /// Collecting, a value that does not decode is recorded with
    /// `defaultValue` as its repair, and `defaultValue` is answered.
    func decode<T: Codable>(
        _ type: T.Type, forKey key: Key, default defaultValue: @autoclosure () -> T,
        in decoder: any Decoder
    ) throws -> T {
        try recording(at: key, in: decoder) {
            try decodeIfPresent(type, forKey: key) ?? defaultValue()
        } fallback: {
            let value = defaultValue()
            return (value, .useDefault(ConfigValueText.encoding(value)))
        }
    }

    /// A list of entries: the list at `key`, or `defaultValue` when the file
    /// holds none there.
    ///
    /// Collecting, an entry that does not decode is recorded at its own
    /// index with removing it as its repair, and the others are kept; a value
    /// that is no list at all is repaired to `defaultValue`.
    func decode<Element: Codable>(
        _ type: [Element].Type, forKey key: Key, default defaultValue: @autoclosure () -> [Element],
        in decoder: any Decoder
    ) throws -> [Element] {
        guard let collector = decoder.collector else {
            return try decodeIfPresent(type, forKey: key) ?? defaultValue()
        }
        let listPath = ConfigValuePath(codingPath: codingPath + [key])
        var entries: any UnkeyedDecodingContainer
        do {
            guard contains(key), try !decodeNil(forKey: key) else { return defaultValue() }
            entries = try nestedUnkeyedContainer(forKey: key)
        } catch {
            let value = defaultValue()
            collector.replaceRecorded(
                since: collector.mark,
                with: ConfigProblemCollector.Recorded(
                    path: listPath, failure: error, repair: .useDefault(ConfigValueText.encoding(value))))
            return value
        }
        var kept: [Element] = []
        while !entries.isAtEnd {
            let index = entries.currentIndex
            let mark = collector.mark
            do {
                kept.append(try entries.decode(Element.self))
            } catch {
                collector.replaceRecorded(
                    since: mark,
                    with: ConfigProblemCollector.Recorded(
                        path: listPath.appending(.index(index)), failure: error, repair: .removeEntry))
                // Past the entry that failed, wherever the failure left the
                // container.
                if entries.currentIndex == index { _ = try? entries.decode(SkippedEntry.self) }
                guard entries.currentIndex > index else { break }
            }
        }
        return kept
    }

    /// A fact: the value at `key`, or `stated` — what a file with no value
    /// there has always meant — when the file holds none.
    ///
    /// Collecting, a value that does not decode is recorded with no repair:
    /// no default stands in for what the file records.
    func decode<T: Codable>(
        _ type: T.Type, forKey key: Key, absentMeans stated: @autoclosure () -> T,
        in decoder: any Decoder
    ) throws -> T {
        try recording(at: key, in: decoder) {
            try decodeIfPresent(type, forKey: key) ?? stated()
        } fallback: {
            (stated(), nil)
        }
    }

    /// A required field with a default: the value at `key`, which a strict
    /// decode refuses to do without.
    ///
    /// Collecting, an absent or unrecognized value is recorded with
    /// `defaultValue` as its repair, and `defaultValue` is answered.
    func decode<T: Codable>(
        _ type: T.Type, forKey key: Key, repairingTo defaultValue: @autoclosure () -> T,
        in decoder: any Decoder
    ) throws -> T {
        try recording(at: key, in: decoder) {
            try decode(type, forKey: key)
        } fallback: {
            let value = defaultValue()
            return (value, .useDefault(ConfigValueText.encoding(value)))
        }
    }

    /// `body`'s value; collecting, a failure is recorded at `key` with the
    /// repair `fallback` names, and `fallback`'s value is answered.
    ///
    /// What the attempt recorded inside the value is dropped: the whole value
    /// is what the repair replaces, and the failure is kept as its cause.
    private func recording<T>(
        at key: Key, in decoder: any Decoder, _ body: () throws -> T,
        fallback: () -> (T, ConfigProblem.Repair?)
    ) throws -> T {
        guard let collector = decoder.collector else { return try body() }
        let mark = collector.mark
        do {
            return try body()
        } catch {
            let (value, repair) = fallback()
            collector.replaceRecorded(
                since: mark,
                with: ConfigProblemCollector.Recorded(
                    path: ConfigValuePath(codingPath: codingPath + [key]), failure: error, repair: repair))
            return value
        }
    }
}

/// Any JSON value, decoded only to step past it.
private struct SkippedEntry: Decodable {
    init(from decoder: any Decoder) throws {}
}

extension Decoder {
    /// The collector a ``ConfigFileDiagnosis`` hands this decoder, `nil` for
    /// a strict decode.
    fileprivate var collector: ConfigProblemCollector? {
        userInfo[.configProblems] as? ConfigProblemCollector
    }
}

extension CodingUserInfoKey {
    /// Where a ``ConfigFileDiagnosis`` hands its decoder the collector that
    /// switches every config field to recording.
    fileprivate static let configProblems: CodingUserInfoKey = {
        guard let key = CodingUserInfoKey(rawValue: "app.kernova.configProblems") else {
            preconditionFailure("CodingUserInfoKey refused a constant raw value")
        }
        return key
    }()
}

/// The config fields a collecting decode met a value it could not decode
/// in, in the order it met them.
final class ConfigProblemCollector: Sendable {
    struct Recorded: Sendable {
        /// The value the repair acts on.
        let path: ConfigValuePath
        /// Why the value did not decode.
        let failure: any Error
        let repair: ConfigProblem.Repair?
    }

    private let recorded = Mutex<[Recorded]>([])

    fileprivate var mark: Int { recorded.withLock { $0.count } }

    /// Drops what was recorded since `mark` and records `entry` — or, where
    /// another form already recorded the value at `entry`'s path, keeps that
    /// one problem, repairable only while both forms can repair it.
    fileprivate func replaceRecorded(since mark: Int, with entry: Recorded) {
        recorded.withLock {
            $0.removeSubrange(mark...)
            guard let earlier = $0.firstIndex(where: { $0.path == entry.path }) else {
                $0.append(entry)
                return
            }
            if entry.repair == nil {
                $0[earlier] = Recorded(path: entry.path, failure: $0[earlier].failure, repair: nil)
            }
        }
    }

    fileprivate var all: [Recorded] { recorded.withLock { $0 } }
}

// MARK: - Diagnosis

/// What decoding one config file's bytes again, recording every problem
/// rather than stopping at the first, found.
///
/// Run over bytes a strict decode refused, so the file is read once.
struct ConfigFileDiagnosis: Sendable {
    /// Every problem met, in file order as the decode met them; the last is
    /// one with no repair when the decode could not finish.
    let problems: [ConfigProblem]
    /// The file's value with every problem's repair made, encoded as the
    /// file's own writes encode it — `nil` unless there is at least one
    /// problem and every one has a repair.
    let repaired: Data?
    /// The string at `$.name`, when the file holds one there.
    let name: String?
    /// The bytes diagnosed.
    let digest: ConfigFileDigest

    /// Decodes `data` as `type` through `decoder`, which this configures to
    /// record; `encoder` is the file's own.
    init<T: Codable>(
        decoding type: T.Type, from data: Data, decoder: JSONDecoder, encoder: JSONEncoder
    ) {
        let tree = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        let collector = ConfigProblemCollector()
        var value: T?
        var unrepairable: ConfigProblem?
        do {
            value = try decoder.decode(type, from: data, collectingInto: collector)
        } catch {
            unrepairable = ConfigProblem(decodingFailure: error, in: tree)
        }
        let recorded = collector.all.map { entry in
            let cause = ConfigProblem(decodingFailure: entry.failure, in: tree)
            return ConfigProblem(
                path: entry.path, issue: cause.issue, repair: entry.repair, issuePath: cause.path)
        }
        problems = recorded + [unrepairable].compactMap { $0 }
        if let value, !problems.isEmpty, problems.allSatisfy(\.isRepairable) {
            repaired = try? encoder.encode(value)
        } else {
            repaired = nil
        }
        name = (tree as? [String: Any])?["name"] as? String
        digest = ConfigFileDigest(of: data)
    }
}

extension JSONDecoder {
    /// `data` decoded as `type` with each config field a problem was met in
    /// at its fallback — a preference or a required field at its default, a
    /// fact at what its absence states, a bad list entry left out — for a
    /// read that must not refuse a value this build does not take. Throws for
    /// a field no config-field form decodes.
    func decodeRepairing<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decode(type, from: data, collectingInto: ConfigProblemCollector())
    }

    /// `data` decoded as `type`, every config field recording into
    /// `collector` rather than throwing.
    fileprivate func decode<T: Decodable>(
        _ type: T.Type, from data: Data, collectingInto collector: ConfigProblemCollector
    ) throws -> T {
        userInfo[.configProblems] = collector
        return try decode(type, from: data)
    }
}

/// A config file's bytes as a check read them, so a repair acts only on the
/// bytes the user reviewed.
struct ConfigFileDigest: Sendable, Hashable {
    private let sha256: Data

    init(of data: Data) {
        sha256 = Data(SHA256.hash(data: data))
    }
}

// MARK: - Problems

/// Where a value sits in a config file, written as a JSON path:
/// `$.networks[0].kind`.
struct ConfigValuePath: Sendable, Hashable, CustomStringConvertible {
    enum Component: Sendable, Hashable {
        case key(String)
        case index(Int)
    }

    let components: [Component]

    init(_ components: [Component]) {
        self.components = components
    }

    /// The path a decoder's coding path names.
    init(codingPath: [any CodingKey]) {
        components = codingPath.map { key in
            if let index = key.intValue { .index(index) } else { .key(key.stringValue) }
        }
    }

    func appending(_ component: Component) -> ConfigValuePath {
        ConfigValuePath(components + [component])
    }

    var description: String {
        components.reduce("$") { path, component in
            switch component {
            case .key(let key): "\(path).\(key)"
            case .index(let index): "\(path)[\(index)]"
            }
        }
    }
}

/// One thing that keeps a config file from being read.
struct ConfigProblem: Sendable, Equatable {
    enum Issue: Sendable, Equatable {
        /// A value the field takes none of.
        case unrecognized(found: String?)
        /// No value where the file needs one.
        case missing
        /// The bytes are not JSON.
        case notJSON(detail: String)
        /// No file where there has to be one.
        case fileMissing
        /// The file is there and could not be read.
        case fileUnreadable(reason: String)
        /// A failure none of the cases above describes.
        case other(reason: String)
    }

    /// What Use Defaults does about a problem.
    enum Repair: Sendable, Equatable {
        /// Puts this default, as the report writes it, in the value's place.
        case useDefault(String)
        /// Removes the list entry the problem is in.
        case removeEntry
    }

    /// The value the problem is about, which its repair replaces or removes;
    /// `nil` for one about the file as a whole.
    let path: ConfigValuePath?
    let issue: Issue
    /// What Use Defaults does about it, `nil` when it can do nothing.
    let repair: Repair?
    /// Where inside the value at ``path`` the issue was met, `nil` when it is
    /// that value itself.
    let issuePath: ConfigValuePath?

    init(
        path: ConfigValuePath?, issue: Issue, repair: Repair? = nil, issuePath: ConfigValuePath? = nil
    ) {
        self.path = path
        self.issue = issue
        self.repair = repair
        self.issuePath = issuePath == path ? nil : issuePath
    }

    /// The problem a decode that threw `error` met, `tree` being the file's
    /// JSON, `nil` when it is not JSON.
    init(decodingFailure error: any Error, in tree: Any?) {
        switch error as? DecodingError {
        case .keyNotFound(let key, let context)?:
            self.init(path: ConfigValuePath(codingPath: context.codingPath + [key]), issue: .missing)
        case .valueNotFound(_, let context)?:
            self.init(path: ConfigValuePath(codingPath: context.codingPath), issue: .missing)
        case .typeMismatch(_, let context)?, .dataCorrupted(let context)?:
            guard tree != nil else {
                let underlying = context.underlyingError as NSError?
                let detail =
                    underlying?.userInfo[NSDebugDescriptionErrorKey] as? String ?? context.debugDescription
                self.init(path: nil, issue: .notJSON(detail: detail))
                return
            }
            let path = ConfigValuePath(codingPath: context.codingPath)
            self.init(path: path, issue: .unrecognized(found: ConfigValueText.found(at: path, in: tree)))
        case nil:
            self.init(path: nil, issue: .other(reason: error.localizedDescription))
        @unknown default:
            self.init(path: nil, issue: .other(reason: error.localizedDescription))
        }
    }

    /// Whether Use Defaults has something to do about it.
    var isRepairable: Bool { repair != nil }

    /// The problem in one clause, in a file named `fileName`.
    func summary(fileName: String) -> String {
        let at = (issuePath ?? path)?.description ?? "$"
        switch issue {
        case .unrecognized(let found?):
            return "\(at): \u{201C}\(found)\u{201D} is not a recognized value"
        case .unrecognized(nil):
            return "\(at): the value is not a recognized one"
        case .missing:
            return "\(at): no value"
        case .notJSON(let detail):
            return "\(fileName) isn\u{2019}t valid JSON (\(Self.clause(detail)))"
        case .fileMissing:
            return "\(fileName) is missing"
        case .fileUnreadable(let reason):
            return "\(fileName) can\u{2019}t be opened: \(Self.clause(reason))"
        case .other(let reason):
            return path == nil && issuePath == nil ? Self.clause(reason) : "\(at): \(Self.clause(reason))"
        }
    }

    /// The problem as the check's report states it: what was found, and what
    /// Use Defaults does about it.
    func reportLine(fileName: String) -> String {
        let summary = summary(fileName: fileName)
        switch repair {
        case .useDefault(let defaultText)?:
            let shown = defaultText.isEmpty ? "\u{201C}\u{201D}" : defaultText
            guard issuePath != nil, let path else { return "\(summary). Default: \(shown)." }
            return "\(summary). Default for \(path): \(shown)."
        case .removeEntry?:
            return "\(summary). Use Defaults removes this entry."
        case nil:
            return "\(summary). Kernova can\u{2019}t repair this file."
        }
    }

    /// `text` without the sentence's closing period, to sit inside another.
    private static func clause(_ text: String) -> String {
        text.hasSuffix(".") ? String(text.dropLast()) : text
    }
}

/// How a config value reads in the report.
enum ConfigValueText {
    /// Longer than this, a found value is cut, so one object or list does not
    /// fill the report.
    static let maximumLength = 80

    /// The value at `path` in `tree`, as text; `nil` when nothing is there.
    static func found(at path: ConfigValuePath, in tree: Any?) -> String? {
        var node = tree
        for component in path.components {
            switch component {
            case .key(let key): node = (node as? [String: Any])?[key]
            case .index(let index):
                guard let array = node as? [Any], array.indices.contains(index) else { return nil }
                node = array[index]
            }
        }
        return node.map(text(of:))
    }

    /// `value` as its JSON encoding reads.
    static func encoding<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
            let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        else { return String(describing: value) }
        return text(of: json)
    }

    /// A string as itself; anything else as compact JSON.
    static func text(of json: Any) -> String {
        let full: String
        switch json {
        case let string as String:
            full = string
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            full = number.boolValue ? "true" : "false"
        case let number as NSNumber:
            full = number.stringValue
        case is NSNull:
            full = "null"
        default:
            let data = try? JSONSerialization.data(
                withJSONObject: json, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
            full = data.flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: json)
        }
        guard full.count > maximumLength else { return full }
        return String(full.prefix(maximumLength - 1)) + "\u{2026}"
    }
}

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
