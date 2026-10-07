import Foundation
import Synchronization

// MARK: - Defaulted fields

extension KeyedDecodingContainer {
    /// The value at `key`, or `defaultValue` when the file holds none there —
    /// the one way a config field with a default decodes.
    ///
    /// A value that is present but does not decode throws, unless `decoder`
    /// is a ``ConfigFileDiagnosis``'s: there it is recorded as a problem whose
    /// repair is `defaultValue`, and `defaultValue` is answered.
    func decode<T: Codable>(
        _ type: T.Type, forKey key: Key, default defaultValue: @autoclosure () -> T,
        in decoder: any Decoder
    ) throws -> T {
        guard let collector = decoder.userInfo[.configProblems] as? ConfigProblemCollector else {
            return try decodeIfPresent(type, forKey: key) ?? defaultValue()
        }
        let mark = collector.mark
        do {
            return try decodeIfPresent(type, forKey: key) ?? defaultValue()
        } catch {
            let fallback = defaultValue()
            // What the attempt recorded inside the value is moot: the whole
            // value is what the default replaces.
            collector.replaceRecorded(
                since: mark,
                with: ConfigProblemCollector.Defaulted(
                    path: ConfigValuePath(codingPath: codingPath + [key]),
                    defaultText: ConfigValueText.encoding(fallback)))
            return fallback
        }
    }
}

extension CodingUserInfoKey {
    /// Where a ``ConfigFileDiagnosis`` hands its decoder the collector that
    /// switches every defaulted field to recording.
    fileprivate static let configProblems: CodingUserInfoKey = {
        guard let key = CodingUserInfoKey(rawValue: "app.kernova.configProblems") else {
            preconditionFailure("CodingUserInfoKey refused a constant raw value")
        }
        return key
    }()
}

/// The defaulted fields a collecting decode met a value it could not decode
/// in, in the order it met them.
final class ConfigProblemCollector: Sendable {
    struct Defaulted: Sendable {
        let path: ConfigValuePath
        let defaultText: String
    }

    private let recorded = Mutex<[Defaulted]>([])

    fileprivate var mark: Int { recorded.withLock { $0.count } }

    fileprivate func replaceRecorded(since mark: Int, with defaulted: Defaulted) {
        recorded.withLock {
            $0.removeSubrange(mark...)
            $0.append(defaulted)
        }
    }

    fileprivate var all: [Defaulted] { recorded.withLock { $0 } }
}

// MARK: - Diagnosis

/// What decoding one config file's bytes again, recording every problem
/// rather than stopping at the first, found.
///
/// Run over bytes a strict decode refused, so the file is read once.
struct ConfigFileDiagnosis: Sendable {
    /// Every problem met, in file order as the decode met them; the last is
    /// one with no default when the decode could not finish.
    let problems: [ConfigProblem]
    /// The file's value with every problem's default in its place, encoded as
    /// the file's own writes encode it — `nil` unless there is at least one
    /// problem and every one has a default.
    let repaired: Data?
    /// The string at `$.name`, when the file holds one there.
    let name: String?

    /// Decodes `data` as `type` through `decoder`, which this configures to
    /// record; `encoder` is the file's own.
    init<T: Codable>(
        decoding type: T.Type, from data: Data, decoder: JSONDecoder, encoder: JSONEncoder
    ) {
        let tree = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        let collector = ConfigProblemCollector()
        decoder.userInfo[.configProblems] = collector
        var value: T?
        var unrepairable: ConfigProblem?
        do {
            value = try decoder.decode(type, from: data)
        } catch {
            unrepairable = ConfigProblem(decodingFailure: error, in: tree)
        }
        let defaulted = collector.all.map {
            ConfigProblem(
                path: $0.path,
                issue: .unrecognized(found: ConfigValueText.found(at: $0.path, in: tree), default: $0.defaultText))
        }
        problems = defaulted + [unrepairable].compactMap { $0 }
        if let value, !problems.isEmpty, problems.allSatisfy(\.isRepairable) {
            repaired = try? encoder.encode(value)
        } else {
            repaired = nil
        }
        name = (tree as? [String: Any])?["name"] as? String
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
        /// A value the field takes none of. `default` is what Use Defaults
        /// puts in its place, `nil` for a field that has no default.
        case unrecognized(found: String?, default: String?)
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

    /// Where the problem is; `nil` for one about the file as a whole.
    let path: ConfigValuePath?
    let issue: Issue

    init(path: ConfigValuePath?, issue: Issue) {
        self.path = path
        self.issue = issue
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
            self.init(
                path: path,
                issue: .unrecognized(found: ConfigValueText.found(at: path, in: tree), default: nil))
        case nil:
            self.init(path: nil, issue: .other(reason: error.localizedDescription))
        @unknown default:
            self.init(path: nil, issue: .other(reason: error.localizedDescription))
        }
    }

    /// Whether Use Defaults has a value to put in its place.
    var isRepairable: Bool {
        guard case .unrecognized(_, .some) = issue else { return false }
        return true
    }

    /// The problem in one clause, in a file named `fileName`.
    func summary(fileName: String) -> String {
        let at = path?.description ?? "$"
        switch issue {
        case .unrecognized(let found?, _):
            return "\(at): \u{201C}\(found)\u{201D} is not a recognized value"
        case .unrecognized(nil, _):
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
            return path == nil ? Self.clause(reason) : "\(at): \(Self.clause(reason))"
        }
    }

    /// The problem as the check's report states it: what was found, and what
    /// Use Defaults does about it.
    func reportLine(fileName: String) -> String {
        guard case .unrecognized(_, let defaultText?) = issue else {
            return "\(summary(fileName: fileName)). Kernova can\u{2019}t repair this file."
        }
        let shown = defaultText.isEmpty ? "\u{201C}\u{201D}" : defaultText
        return "\(summary(fileName: fileName)). Default: \(shown)."
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

    init(location: Location, owner: Owner, problems: [ConfigProblem]) {
        assert(!problems.isEmpty, "An unreadable file names at least one problem")
        self.location = location
        self.owner = owner
        self.problems = problems
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
                : diagnosis.problems)
    }

    var url: URL { location.url }

    var fileName: String { url.lastPathComponent }

    /// Whether Use Defaults rewrites it: every problem has a default.
    var isRepairable: Bool { problems.allSatisfy(\.isRepairable) }

    /// The first problem, in one clause.
    var summary: String { problems[0].summary(fileName: fileName) }

    var errorDescription: String? {
        "\u{201C}\(fileName)\u{201D} could not be read: \(summary)."
    }
}
