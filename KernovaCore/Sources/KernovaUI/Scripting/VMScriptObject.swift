import Cocoa
import KernovaCommandModel
import KernovaCore
import KernovaLogging

/// One VM as the scripting dictionary's `virtual machine`, each ``VMInfo``
/// field read by the key ``key(carrying:)`` names for it.
///
/// A copy of one read, not a handle: the container rebuilds the whole list on
/// every specifier evaluation, so a script always reads a VM as it stands now
/// and nothing here has to be kept current. Setting `name` is the rename verb,
/// and its other writable properties are configuration keys, which setting
/// writes through the `setConfiguration` verb; the gateway runs either and
/// records a refusal on the command being answered.
@MainActor
@objc(VMScriptObject)
package final class VMScriptObject: NSObject {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMScriptObject")

    /// The read every property answers from.
    private let info: VMInfo
    /// Where a write runs.
    private weak var gateway: VMScriptingGateway?

    init(_ info: VMInfo, gateway: VMScriptingGateway) {
        self.info = info
        self.gateway = gateway
    }

    /// How the command vocabulary addresses the VM this stands for.
    nonisolated var selector: VMSelector { .id(info.id) }

    // MARK: - Properties

    @objc var uniqueID: String { info.id.uuidString }

    @objc var name: String {
        get { info.name }
        set { gateway?.rename(info.id, to: newValue) }
    }

    /// The `VM state` enumerator for the VM's status, as the Apple event code
    /// the dictionary gives it.
    ///
    /// `missing value` for a status from no vocabulary this app writes, which
    /// is a programming error rather than a state a script can provoke.
    @objc var state: NSNumber? {
        guard let state = VMScriptState(wireName: info.status) else {
            Self.logger.log(
                .fault,
                "VM status '\(self.info.status, privacy: .public)' has no scripting term")
            assertionFailure("VM status '\(info.status)' has no scripting term")
            return nil
        }
        return NSNumber(value: state.code)
    }

    @objc var guestOperatingSystem: String { info.guestOS.rawValue }

    @objc var processorCount: Int { info.cpuCount }

    /// Guest memory in gigabytes — the unit the `memory` configuration key
    /// reads and writes, so one number means one thing on every surface.
    @objc var memory: Double { Double(info.memoryBytes) / Double(1 << 30) }

    /// `missing value` written is networking turned off, as a read answers it.
    @objc var networkMode: String? {
        get { info.networkMode?.rawValue }
        set {
            write(
                VMConfigurationKeyRegistry.networkMode,
                newValue ?? VMConfigurationKeyRegistry.noNetworkValue)
        }
    }

    @objc var networkMembership: String? {
        get { info.networkMembership }
        set { write(VMConfigurationKeyRegistry.networkMembership, newValue ?? "") }
    }

    @objc var networkName: String? { info.networkName?.title }

    @objc var macAddress: String? {
        get { info.macAddress }
        set { write(VMConfigurationKeyRegistry.networkMAC, newValue ?? "") }
    }

    @objc var ipAddress: String? { info.ipAddress.address }

    @objc var agentStatus: String? { info.agentStatus }

    /// ``VMInfo/guestAgent`` as its wire name.
    @objc var agentVersion: String? { info.guestAgent?.rawValue }

    @objc var hasSavedState: Bool { info.hasSavedState }

    @objc var savedStateVersion: String? { info.savedStateKernovaVersion }

    @objc var ephemeral: Bool { info.isEphemeral }

    @objc var snapshotCount: Int { info.snapshotCount }

    @objc var hasSnapshots: Bool { info.hasSnapshots }

    /// The `VM state group` enumerator for ``VMInfo/stateBucket``, as the
    /// Apple event code the dictionary gives it.
    @objc var stateGroup: NSNumber { NSNumber(value: VMScriptStateGroup(info.stateBucket).code) }

    @objc var tags: [String]? { info.tags }

    @objc var creationDate: Date { info.createdAt }

    @objc var lastRunDate: Date? { info.lastRunAt }

    @objc var bundlePath: String { info.bundlePath }

    private func write(_ key: VMConfigurationKey, _ value: String) {
        gateway?.setConfiguration(info.id, key: key, value: value)
    }

    /// The Cocoa key of the property or element the dictionary reads `field`
    /// by — the key `Kernova.sdef` gives that term, which
    /// `KernovaScriptingDefinitionTests` checks — or `nil` for a field no term
    /// reads.
    static func key(carrying field: VMInfo.Field) -> String? {
        switch field {
        case .id: #keyPath(VMScriptObject.uniqueID)
        case .name: #keyPath(VMScriptObject.name)
        case .status: #keyPath(VMScriptObject.state)
        case .guestOS: #keyPath(VMScriptObject.guestOperatingSystem)
        case .cpuCount: #keyPath(VMScriptObject.processorCount)
        case .memoryBytes: #keyPath(VMScriptObject.memory)
        case .networkMode: #keyPath(VMScriptObject.networkMode)
        case .networkMembership: #keyPath(VMScriptObject.networkMembership)
        case .networkName: #keyPath(VMScriptObject.networkName)
        case .macAddress: #keyPath(VMScriptObject.macAddress)
        case .ipAddress: #keyPath(VMScriptObject.ipAddress)
        case .agentStatus: #keyPath(VMScriptObject.agentStatus)
        case .hasSavedState: #keyPath(VMScriptObject.hasSavedState)
        case .savedStateKernovaVersion: #keyPath(VMScriptObject.savedStateVersion)
        case .isEphemeral: #keyPath(VMScriptObject.ephemeral)
        case .snapshotCount: #keyPath(VMScriptObject.snapshotCount)
        case .hasSnapshots: #keyPath(VMScriptObject.hasSnapshots)
        case .guestAgent: #keyPath(VMScriptObject.agentVersion)
        case .stateBucket: #keyPath(VMScriptObject.stateGroup)
        case .bundlePath: #keyPath(VMScriptObject.bundlePath)
        // `state group` is `held by another copy` exactly when this is true.
        case .heldByAnotherCopy: nil
        case .agents: Self.guestAgentsKey
        case .tags: #keyPath(VMScriptObject.tags)
        case .createdAt: #keyPath(VMScriptObject.creationDate)
        case .lastRunAt: #keyPath(VMScriptObject.lastRunDate)
        }
    }

    // MARK: - Elements

    /// The literal KVC key the dictionary's `storage disk` element is declared
    /// with.
    nonisolated static let storageDisksKey = "storageDisks"

    /// The literal KVC key the dictionary's `guest agent` element is declared
    /// with.
    nonisolated static let guestAgentsKey = "guestAgents"

    /// The literal KVC key the dictionary's `snapshot` element is declared
    /// with.
    nonisolated static let snapshotsKey = "snapshots"

    /// Every disk the VM attaches, in attachment order, measured
    /// for the command being answered — see
    /// ``VMScriptingGateway/storageDisks(of:)``.
    @objc var storageDisks: [VMStorageDiskScriptObject] {
        gateway?.storageDisks(of: info.id) ?? []
    }

    /// ``VMInfo/agents``, in its order.
    @objc var guestAgents: [VMGuestAgentScriptObject] {
        info.agents.enumerated().map { VMGuestAgentScriptObject($0.element, at: $0.offset, of: info.id) }
    }

    /// The VM's snapshots, newest first — see
    /// ``VMScriptingGateway/snapshots(of:)``.
    @objc var snapshots: [VMSnapshotScriptObject] {
        gateway?.snapshots(of: info.id) ?? []
    }

    /// The named-element accessor Cocoa resolves `snapshot "…"` through —
    /// see ``VMScriptingGateway/snapshot(named:of:)``.
    ///
    /// Cocoa's own answer is the first snapshot whose name matches, and
    /// several snapshots of one VM can share a name.
    @objc(valueInSnapshotsWithName:)
    func valueInSnapshots(withName name: String) -> VMSnapshotScriptObject? {
        gateway?.snapshot(named: name, of: info.id)
    }

    /// Takes a snapshot of the VM for `make new snapshot at` it — see
    /// ``VMScriptingGateway/makeSnapshot(of:name:notes:)``.
    func makeSnapshot(name: String?, notes: String?) {
        gateway?.makeSnapshot(of: info.id, name: name, notes: notes)
    }

    /// Refuses `make new storage disk at` or `make new guest agent at` a VM:
    /// a script adds neither. A snapshot's make never reaches this
    /// (``VMCreateScriptCommand``).
    ///
    /// Cocoa's own answer allocates the element's class with `init()`, which
    /// neither ``VMStorageDiskScriptObject`` nor ``VMGuestAgentScriptObject``
    /// has — so it would trap.
    package nonisolated override func newScriptingObject(
        of objectClass: AnyClass, forValueForKey key: String, withContentsValue contentsValue: Any?,
        properties: [String: Any]
    ) -> Any? {
        MainActor.assumeIsolated {
            gateway?.refuseToMake(
                key == Self.guestAgentsKey
                    ? VMScriptingGateway.cannotMakeGuestAgent : VMScriptingGateway.cannotMakeStorageDisk)
        }
        return nil
    }

    /// Where Cocoa re-inserts a snapshot a `move` removed: there is no order
    /// to move one in, so there is nothing to insert. Without it, Cocoa's KVC
    /// falls back to a setter the element has none of, which raises.
    @objc(insertInSnapshots:)
    func insertInSnapshots(_ snapshot: Any) {}

    /// The positional spelling of ``insertInSnapshots(_:)``: the snapshots are
    /// ordered newest first, so the position names nothing.
    @objc(insertInSnapshots:atIndex:)
    func insertInSnapshots(_ snapshot: Any, at index: Int) {}

    /// Where Cocoa removes a snapshot by index, which only a `move` reaches —
    /// every `delete` naming a snapshot, one reference or a list of them, goes
    /// to ``VMScriptingGateway/delete(_:in:for:)`` — and
    /// ``VMScriptingGateway/refuseToMoveSnapshot()`` refuses.
    @objc(removeFromSnapshotsAtIndex:)
    func removeFromSnapshots(at index: Int) {
        gateway?.refuseToMoveSnapshot()
    }

    // MARK: - Specifier

    /// How a script names this VM back — `virtual machine id "…"` of the
    /// application, which is the one form no rename or reorder invalidates.
    package nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        Self.specifier(for: info.id)
    }

    /// `virtual machine id "…"` of the application, for the VM `id` identifies.
    nonisolated static func specifier(for id: UUID) -> NSScriptObjectSpecifier? {
        guard let application = NSScriptClassDescription(for: NSApplication.self) else {
            Self.logger.log(.fault, "NSApplication has no scripting class description")
            assertionFailure("NSApplication has no scripting class description")
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: application,
            containerSpecifier: nil,
            key: VMScriptingRoot.virtualMachinesKey,
            uniqueID: id.uuidString)
    }
}

// MARK: - VM state

/// The dictionary's `VM state` enumeration, in Swift.
///
/// The cases and codes here and the enumerators in `Kernova.sdef` are two
/// halves of one thing, which is what `KernovaScriptingDefinitionTests` checks.
enum VMScriptState: CaseIterable {
    case stopped
    case starting
    case running
    case paused
    case suspended
    case saving
    case snapshotting
    case cloning
    case restoring
    case installing
    case forceStopping
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
        case .suspended: self = .suspended
        case .saving: self = .saving
        case .snapshotting: self = .snapshotting
        case .cloning: self = .cloning
        case .restoring: self = .restoring
        case .installing: self = .installing
        case .forceStopping: self = .forceStopping
        case .initialBoot: self = .initialBoot
        case .error: self = .failed
        }
    }

    /// The Apple event code the dictionary gives this case's term.
    var code: FourCharCode {
        switch self {
        case .stopped: FourCharCode(scriptingCode: "KsSt")
        case .starting: FourCharCode(scriptingCode: "KsSg")
        case .running: FourCharCode(scriptingCode: "KsRn")
        case .paused: FourCharCode(scriptingCode: "KsPs")
        case .suspended: FourCharCode(scriptingCode: "KsSu")
        case .saving: FourCharCode(scriptingCode: "KsSv")
        case .snapshotting: FourCharCode(scriptingCode: "KsSn")
        case .cloning: FourCharCode(scriptingCode: "KsCl")
        case .restoring: FourCharCode(scriptingCode: "KsRs")
        case .installing: FourCharCode(scriptingCode: "KsIn")
        case .forceStopping: FourCharCode(scriptingCode: "KsFs")
        case .initialBoot: FourCharCode(scriptingCode: "KsIb")
        case .failed: FourCharCode(scriptingCode: "KsEr")
        case .preparing: FourCharCode(scriptingCode: "KsPr")
        }
    }
}

// MARK: - VM state group

/// The dictionary's `VM state group` enumeration, in Swift — the other half of
/// its enumerators in `Kernova.sdef`, which `KernovaScriptingDefinitionTests`
/// checks.
///
/// A group whose word is also a `VM state` term takes that enumerator's code,
/// so `state group of virtual machine 1 is running` compares the one constant
/// `running` names.
enum VMScriptStateGroup {
    case running
    case suspended
    case stopped
    case heldByAnotherCopy
    case preparing

    /// The term `bucket` is named by. Exhaustive, so a new group has to be
    /// given a term before it compiles.
    init(_ bucket: VMStateBucket) {
        switch bucket {
        case .running: self = .running
        case .suspended: self = .suspended
        case .stopped: self = .stopped
        case .heldByAnotherCopy: self = .heldByAnotherCopy
        case .preparing: self = .preparing
        }
    }

    /// The Apple event code the dictionary gives this case's term.
    var code: FourCharCode {
        switch self {
        case .running: VMScriptState.running.code
        case .suspended: VMScriptState.suspended.code
        case .stopped: VMScriptState.stopped.code
        case .heldByAnotherCopy: FourCharCode(scriptingCode: "KsHc")
        case .preparing: VMScriptState.preparing.code
        }
    }
}

// MARK: - Apple event codes

extension FourCharCode {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "ScriptingCode")

    /// The Apple event code four ASCII characters spell.
    ///
    /// Every caller passes a literal that also appears as a `code` attribute in
    /// `Kernova.sdef`; anything else is a typo rather than input.
    init(scriptingCode text: String) {
        let bytes = Array(text.utf8)
        guard bytes.count == 4 else {
            Self.logger.log(
                .fault,
                "Apple event code '\(text, privacy: .public)' is not four ASCII characters")
            assertionFailure("Apple event code '\(text)' is not four ASCII characters")
            self = 0
            return
        }
        self = bytes.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}
