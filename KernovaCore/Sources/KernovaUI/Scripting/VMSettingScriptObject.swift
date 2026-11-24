import Cocoa
import CoreServices
import KernovaCommandModel
import KernovaCore
import KernovaLogging

/// One setting, as a verb a script runs names it: the VM it belongs to, its
/// key, and what its value is.
struct VMSettingAddress: Hashable, Sendable {
    let vm: UUID
    let key: String
    let kind: ConfigurationValueKind
}

/// One of a VM's settings, as the scripting dictionary's `setting`: a key of
/// the keyspace, its value as ``VMCommandCore/configuration(_:keys:)`` reads
/// it, typed as the key's kind is (``VMScriptSettingValue``), and the key's
/// summary.
///
/// A copy of one read, like ``VMScriptObject``: the VM reads its settings
/// afresh on every specifier evaluation. Setting `value` is the settings
/// write, run by ``VMScriptingGateway/setSetting(_:to:)``.
@MainActor
@objc(VMSettingScriptObject)
package final class VMSettingScriptObject: NSObject {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMSettingScriptObject")

    /// What the setting held when read.
    private let held: ConfigurationTypedValue
    /// Which setting it is.
    let address: VMSettingAddress
    /// Where a write runs.
    private weak var gateway: VMScriptingGateway?

    /// What the key holds and the values it takes, in one line.
    @objc let summary: String

    /// `entry`, a setting of the VM `vm` identifies, as `descriptor` — its
    /// key's — describes it.
    init(
        _ entry: ConfigurationEntry, describedBy descriptor: ConfigurationKeyDescriptor, of vm: UUID,
        gateway: VMScriptingGateway
    ) {
        held = Self.value(entry, as: descriptor.kind)
        summary = descriptor.summary
        address = VMSettingAddress(vm: vm, key: entry.key, kind: descriptor.kind)
        self.gateway = gateway
    }

    /// `entry`'s value as `kind` reads it.
    ///
    /// The core wrote the text with the codec `kind` names, so it parses; a
    /// value that doesn't is a programming error, answered as the text.
    static func value(_ entry: ConfigurationEntry, as kind: ConfigurationValueKind) -> ConfigurationTypedValue {
        do {
            return try kind.value(entry.value, key: entry.key)
        } catch {
            logger.log(
                .fault,
                "Setting \(entry.key, privacy: .public) read \(entry.value, privacy: .public), which its kind \(kind.rawValue, privacy: .public) refuses"
            )
            assertionFailure("Setting \(entry.key) read \(entry.value), which its kind \(kind) refuses")
            return .text(entry.value)
        }
    }

    // MARK: - Properties

    @objc var name: String { address.key }

    /// ``VMScriptSettingValue``: the dictionary declares `value` as `any`.
    @objc var value: Any? {
        get { VMScriptSettingValue(held) }
        set { gateway?.setSetting(address, to: newValue) }
    }

    // MARK: - Specifier

    /// How a script names this setting back — `setting "<key>"` of
    /// `virtual machine id "…"`: a key names one setting of a VM.
    package nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        Self.specifier(for: address)
    }

    /// `setting "<key>"` of `virtual machine id "…"`, for the setting
    /// `address` names.
    nonisolated static func specifier(for address: VMSettingAddress) -> NSScriptObjectSpecifier? {
        guard let virtualMachine = NSScriptClassDescription(for: VMScriptObject.self) else {
            Self.logger.log(.fault, "VMScriptObject has no scripting class description")
            assertionFailure("VMScriptObject has no scripting class description")
            return nil
        }
        return NSNameSpecifier(
            containerClassDescription: virtualMachine,
            containerSpecifier: VMScriptObject.specifier(for: address.vm),
            key: VMScriptObject.settingsKey,
            name: address.key)
    }
}

// MARK: - Value

/// A setting's value as a script reads it: a boolean, an integer, a real
/// number of gigabytes, a `VM network mode` constant or missing value, or
/// text, as its key's kind is.
///
/// The dictionary's `any` is NSAppleEventDescriptor (Cocoa Scripting Guide,
/// "Support for basic AppleScript types"), so the value reaches a script as
/// itself, and an `if` compares it as AppleScript compares that type. A
/// `whose` test asks the value it reads to compare itself when it implements
/// `NSScriptingComparisonMethods` (NSScriptWhoseTests.h), which
/// NSAppleEventDescriptor doesn't, so this does, from what the descriptor
/// holds and for each of the eight tests:
/// - text with text, through NSString's own implementations, which Cocoa
///   compares every text property with: ignoring case and considering
///   diacriticals, as an `if` does unless told otherwise, and blind to
///   `considering case`;
/// - a number with a number;
/// - a boolean, a constant or missing value with its equal, which is also
///   all such a value contains, begins or ends with, as in an `if`.
///
/// Any other test is false: two values of different types, which an `if` may
/// first convert, and a boolean, constant or missing value ordered, which an
/// `if` stops at or answers false.
///
/// NSAppleEventDescriptor makes a copy or a coercion of one as one of this
/// class, through ``init(aeDescNoCopy:)``, which compares as what it then
/// holds.
final class VMScriptSettingValue: NSAppleEventDescriptor {
    convenience init(_ value: ConfigurationTypedValue) {
        var desc = AEDesc()
        if let plain = Self.descriptor(value).aeDesc {
            AEDuplicateDesc(plain, &desc)
        }
        self.init(aeDescNoCopy: &desc)
    }

    override init(aeDescNoCopy aeDesc: UnsafePointer<AEDesc>) {
        super.init(aeDescNoCopy: aeDesc)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// `value` as a plain descriptor of its type.
    private static func descriptor(_ value: ConfigurationTypedValue) -> NSAppleEventDescriptor {
        switch value {
        case .boolean(let value): NSAppleEventDescriptor(boolean: value)
        case .integer(let value): NSAppleEventDescriptor(int32: Int32(clamping: value))
        case .gigabytes(let size): NSAppleEventDescriptor(double: size.gibibytes)
        case .networkMode(let mode?): NSAppleEventDescriptor(enumCode: VMScriptNetworkMode(mode).code)
        case .networkMode(nil): missingValue
        case .text(let text): NSAppleEventDescriptor(string: text)
        }
    }

    /// AppleScript's `missing value`.
    private static var missingValue: NSAppleEventDescriptor {
        NSAppleEventDescriptor(typeCode: FourCharCode(scriptingCode: "msng"))
    }

    // MARK: Comparison

    /// What a value is, as these comparisons read it.
    private enum Operand {
        case number(Double)
        case boolean(Bool)
        case text(String)
        case constant(FourCharCode)
        case missing
        case other

        init(_ value: Any) {
            switch value {
            case let descriptor as NSAppleEventDescriptor: self.init(descriptor)
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
                self = .boolean(number.boolValue)
            case let number as NSNumber: self = .number(number.doubleValue)
            case let text as String: self = .text(text)
            case is NSNull: self = .missing
            default: self = .other
            }
        }

        init(_ descriptor: NSAppleEventDescriptor) {
            switch descriptor.descriptorType {
            case typeTrue, typeFalse, typeBoolean: self = .boolean(descriptor.booleanValue)
            case typeSInt16, typeSInt32, typeSInt64, typeUInt16, typeUInt32, typeUInt64,
                typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint:
                self = .number(descriptor.doubleValue)
            case typeUnicodeText, typeUTF8Text, typeUTF16ExternalRepresentation, typeChar:
                self = descriptor.stringValue.map(Operand.text) ?? .other
            case typeEnumerated: self = .constant(descriptor.enumCodeValue)
            case typeType where descriptor.typeCodeValue == FourCharCode(scriptingCode: "msng"): self = .missing
            default: self = .other
            }
        }
    }

    /// One of a `whose` test's comparisons.
    private enum Test {
        case equal, lessThan, lessThanOrEqual, greaterThan, greaterThanOrEqual, beginsWith, endsWith, contains

        /// What it answers for two values that order as `order` says, `nil`
        /// for two that don't.
        func answer(ordered order: ComparisonResult?) -> Bool {
            switch self {
            case .lessThan: order == .orderedAscending
            case .lessThanOrEqual: order == .orderedAscending || order == .orderedSame
            case .greaterThan: order == .orderedDescending
            case .greaterThanOrEqual: order == .orderedDescending || order == .orderedSame
            case .equal, .beginsWith, .endsWith, .contains: order == .orderedSame
            }
        }

        /// What it answers for two values of a type with no order.
        func answer(equal: Bool) -> Bool {
            switch self {
            case .equal, .beginsWith, .endsWith, .contains: equal
            case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual: false
            }
        }

        /// What it answers for `text` against `other`.
        func answer(_ text: NSString, _ other: String) -> Bool {
            switch self {
            case .equal: text.scriptingIsEqual(to: other)
            case .lessThan: text.scriptingIsLessThan(other)
            case .lessThanOrEqual: text.scriptingIsLessThanOrEqual(to: other)
            case .greaterThan: text.scriptingIsGreaterThan(other)
            case .greaterThanOrEqual: text.scriptingIsGreaterThanOrEqual(to: other)
            case .beginsWith: text.scriptingBegins(with: other)
            case .endsWith: text.scriptingEnds(with: other)
            case .contains: text.scriptingContains(other)
            }
        }
    }

    /// What `test` answers for this value against `object`, a `whose` test's
    /// value.
    private func answers(_ test: Test, against object: Any) -> Bool {
        switch (Operand(self), Operand(object)) {
        case (.text(let text), .text(let other)): test.answer(text as NSString, other)
        case (.number(let number), .number(let other)): test.answer(ordered: Self.order(number, other))
        case (.boolean(let value), .boolean(let other)): test.answer(equal: value == other)
        case (.constant(let code), .constant(let other)): test.answer(equal: code == other)
        case (.missing, .missing): test.answer(equal: true)
        default: false
        }
    }

    private static func order(_ lhs: Double, _ rhs: Double) -> ComparisonResult? {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return lhs == rhs ? .orderedSame : nil
    }

    override func scriptingIsEqual(to object: Any) -> Bool { answers(.equal, against: object) }
    override func scriptingIsLessThan(_ object: Any) -> Bool { answers(.lessThan, against: object) }
    override func scriptingIsLessThanOrEqual(to object: Any) -> Bool { answers(.lessThanOrEqual, against: object) }
    override func scriptingIsGreaterThan(_ object: Any) -> Bool { answers(.greaterThan, against: object) }
    override func scriptingIsGreaterThanOrEqual(to object: Any) -> Bool {
        answers(.greaterThanOrEqual, against: object)
    }
    override func scriptingBegins(with object: Any) -> Bool { answers(.beginsWith, against: object) }
    override func scriptingEnds(with object: Any) -> Bool { answers(.endsWith, against: object) }
    override func scriptingContains(_ object: Any) -> Bool { answers(.contains, against: object) }

    // MARK: Writing

    /// `value`, what a script wrote to the setting `address` names, as the
    /// text the core takes: a value of the setting's type spelled as its
    /// codec spells it, a `VM network mode` constant as its mode's name, and
    /// text as written, for the core to parse.
    ///
    /// A reference is evaluated first: `set value of s to value of s` sends
    /// the property it names, not what that holds, because `value` is `any`.
    ///
    /// - Throws: ``CommandError/invalidArgument(_:)`` for missing value
    ///   anywhere but `network.mode`, another constant, and anything that is
    ///   no single value.
    static func text(of value: Any?, for address: VMSettingAddress) throws -> String {
        guard let reference = value as? NSAppleEventDescriptor, reference.descriptorType == typeObjectSpecifier else {
            return try text(ofValue: value, for: address)
        }
        guard let evaluated = NSScriptObjectSpecifier(descriptor: reference)?.objectsByEvaluatingSpecifier else {
            throw notAValue(for: address)
        }
        return try text(ofValue: evaluated, for: address)
    }

    /// ``text(of:for:)`` for a value that is no reference.
    private static func text(ofValue value: Any?, for address: VMSettingAddress) throws -> String {
        switch value {
        case let descriptor as NSAppleEventDescriptor: return try text(of: descriptor, for: address)
        case let text as String: return text
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return ConfigurationTypedValue.boolean(number.boolValue).text
        case let number as NSNumber: return text(ofNumber: number.doubleValue, for: address)
        case nil, is NSNull: return try missing(for: address)
        default: throw notAValue(for: address)
        }
    }

    private static func text(of descriptor: NSAppleEventDescriptor, for address: VMSettingAddress) throws -> String {
        switch Operand(descriptor) {
        case .boolean(let value): return ConfigurationTypedValue.boolean(value).text
        case .number(let value): return text(ofNumber: value, for: address)
        case .text(let text): return text
        case .constant(let code):
            guard let mode = VMScriptNetworkMode(code: code) else {
                throw CommandError.invalidArgument(
                    "The constants a setting takes are nat, bridged and host only, which network.mode takes.")
            }
            return ConfigurationTypedValue.networkMode(mode.mode).text
        case .missing: return try missing(for: address)
        case .other: throw notAValue(for: address)
        }
    }

    /// A number written to the setting `address` names: gigabytes to the
    /// megabyte where it holds a size, a whole number without decimals.
    private static func text(ofNumber value: Double, for address: VMSettingAddress) -> String {
        if address.kind == .gigabytes, let size = VMMemorySize(gibibytes: value) {
            return ConfigurationTypedValue.gigabytes(size).text
        }
        if let whole = Int(exactly: value) { return ConfigurationTypedValue.integer(whole).text }
        return String(value)
    }

    /// `missing value` written to the setting `address` names: no network
    /// device, for the one setting whose missing value is that.
    private static func missing(for address: VMSettingAddress) throws -> String {
        guard address.kind == .networkMode else {
            throw CommandError.invalidArgument("\(address.key) takes a value, not missing value.")
        }
        return ConfigurationTypedValue.networkMode(nil).text
    }

    private static func notAValue(for address: VMSettingAddress) -> CommandError {
        .invalidArgument("\(address.key) takes one value.")
    }
}
