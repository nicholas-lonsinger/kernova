import Cocoa
import KernovaKit
import os

/// One VM as the scripting dictionary's `virtual machine`, one property per
/// ``VMInfo`` field.
///
/// A snapshot, not a handle: the container rebuilds the whole list on every
/// specifier evaluation, so a script always reads a VM as it stands now and
/// nothing here has to be kept current.
@objc(VMScriptObject)
final class VMScriptObject: NSObject {
    private static let logger = Logger(subsystem: "app.kernova", category: "VMScriptObject")

    /// The read every property answers from.
    private let info: VMInfo

    init(_ info: VMInfo) {
        self.info = info
    }

    /// How the command vocabulary addresses the VM this stands for.
    var selector: VMSelector { .id(info.id) }

    // MARK: - Properties

    @objc var uniqueID: String { info.id.uuidString }

    @objc var name: String { info.name }

    /// The `VM state` enumerator for the VM's status, as the Apple event code
    /// the dictionary gives it.
    ///
    /// `missing value` for a status from no vocabulary this app writes, which
    /// is a programming error rather than a state a script can provoke.
    @objc var state: NSNumber? {
        guard let state = VMScriptState(wireName: info.status) else {
            Self.logger.fault(
                "VM status '\(self.info.status, privacy: .public)' has no scripting term")
            assertionFailure("VM status '\(info.status)' has no scripting term")
            return nil
        }
        return NSNumber(value: state.code)
    }

    @objc var guestOperatingSystem: String { info.guestOS }

    @objc var processorCount: Int { info.cpuCount }

    /// Guest memory in whole gigabytes — the unit the `memory` configuration
    /// key reads and writes, so one number means one thing on every surface.
    @objc var memory: Int { Int(info.memoryBytes / (1 << 30)) }

    @objc var diskSize: Int { info.diskSizeInGB }

    @objc var networkMode: String? { info.networkMode }

    @objc var macAddress: String? { info.macAddress }

    @objc var ipAddress: String? { info.ipAddress.reservedAddress }

    @objc var agentStatus: String { info.agentStatus }

    @objc var hasSavedState: Bool { info.hasSavedState }

    @objc var ephemeral: Bool { info.isEphemeral }

    @objc var snapshotCount: Int { info.snapshotCount }

    @objc var bundlePath: String { info.bundlePath }

    // MARK: - Specifier

    /// How a script names this VM back — `virtual machine id "…"` of the
    /// application, which is the one form no rename or reorder invalidates.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let application = NSScriptClassDescription(for: NSApplication.self) else {
            Self.logger.fault("NSApplication has no scripting class description")
            assertionFailure("NSApplication has no scripting class description")
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: application,
            containerSpecifier: nil,
            key: "virtualMachines",
            uniqueID: uniqueID)
    }
}

// MARK: - VM state

/// The dictionary's `VM state` enumeration, in Swift.
///
/// The terms and codes here and the enumerators in `Kernova.sdef` are two
/// halves of one thing, which is what `KernovaScriptingDefinitionTests` checks.
enum VMScriptState: CaseIterable {
    case stopped
    case starting
    case running
    case paused
    case saving
    case snapshotting
    case restoring
    case installing
    case initialBoot
    /// ``VMStatus/error`` under a term AppleScript can parse: `error` is a
    /// reserved word there, so a script comparing against it would not compile.
    case failed
    case preparing

    /// The state a VM reporting `wireName` is in, `nil` for a name from no
    /// vocabulary this app writes.
    init?(wireName: String) {
        if wireName == VMStatus.preparingWireName {
            self = .preparing
            return
        }
        guard let status = VMStatus(rawValue: wireName) else { return nil }
        self.init(status)
    }

    /// The state `status` names. Exhaustive, so a new status has to be given a
    /// term before it compiles.
    init(_ status: VMStatus) {
        switch status {
        case .stopped: self = .stopped
        case .starting: self = .starting
        case .running: self = .running
        case .paused: self = .paused
        case .saving: self = .saving
        case .snapshotting: self = .snapshotting
        case .restoring: self = .restoring
        case .installing: self = .installing
        case .initialBoot: self = .initialBoot
        case .error: self = .failed
        }
    }

    /// The term the dictionary names this state with.
    var term: String {
        switch self {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .paused: "paused"
        case .saving: "saving"
        case .snapshotting: "snapshotting"
        case .restoring: "restoring"
        case .installing: "installing"
        case .initialBoot: "initial boot"
        case .failed: "failed"
        case .preparing: "preparing"
        }
    }

    /// The Apple event code the dictionary gives that term.
    var code: FourCharCode {
        switch self {
        case .stopped: FourCharCode(scriptingCode: "KsSt")
        case .starting: FourCharCode(scriptingCode: "KsSg")
        case .running: FourCharCode(scriptingCode: "KsRn")
        case .paused: FourCharCode(scriptingCode: "KsPs")
        case .saving: FourCharCode(scriptingCode: "KsSv")
        case .snapshotting: FourCharCode(scriptingCode: "KsSn")
        case .restoring: FourCharCode(scriptingCode: "KsRs")
        case .installing: FourCharCode(scriptingCode: "KsIn")
        case .initialBoot: FourCharCode(scriptingCode: "KsIb")
        case .failed: FourCharCode(scriptingCode: "KsEr")
        case .preparing: FourCharCode(scriptingCode: "KsPr")
        }
    }
}

// MARK: - Apple event codes

extension FourCharCode {
    private static let logger = Logger(subsystem: "app.kernova", category: "ScriptingCode")

    /// The Apple event code four ASCII characters spell.
    ///
    /// Every caller passes a literal that also appears as a `code` attribute in
    /// `Kernova.sdef`; anything else is a typo rather than input.
    init(scriptingCode text: String) {
        let bytes = Array(text.utf8)
        guard bytes.count == 4 else {
            Self.logger.fault(
                "Apple event code '\(text, privacy: .public)' is not four ASCII characters")
            assertionFailure("Apple event code '\(text)' is not four ASCII characters")
            self = 0
            return
        }
        self = bytes.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}
