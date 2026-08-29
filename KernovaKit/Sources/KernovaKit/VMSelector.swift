import Foundation

/// How a caller names one virtual machine.
///
/// Display names are not unique, so a name that matches more than one VM
/// resolves to an ambiguity refusal carrying every candidate rather than to a
/// guess.
public enum VMSelector: Codable, Sendable, Hashable {
    /// The VM's stable identifier.
    case id(UUID)
    /// The VM's display name, matched exactly and case-sensitively.
    case name(String)
    /// Text typed by a user: read as an identifier when it parses as one and
    /// names a VM, otherwise as a display name.
    case idOrName(String)

    /// How this selector reads back in a message to the user.
    public var displayText: String {
        switch self {
        case .id(let id): id.uuidString
        case .name(let name), .idOrName(let name): name
        }
    }
}

/// One command in the facade's vocabulary.
///
/// Named rather than described so a refusal can list the verbs a VM's current
/// state does allow, and so each transport can map a verb to its own naming.
public enum VMVerb: String, Codable, Sendable, Hashable, CaseIterable {
    case list
    case info
    case ipAddress
    case snapshots
    case start
    case stop
    case pause
    case resume
    case suspend
    case restart
    case open
    case takeSnapshot
    case revertToSnapshot
    case deleteSnapshot
    case renameSnapshot
    case setSnapshotNotes
    case clone
    case rename
    case delete
    case importVM
    case cancelPreparing
}

/// How a stop should reach a powered-off guest.
public enum StopDisposition: String, Codable, Sendable, Hashable, CaseIterable {
    /// Request an ACPI shutdown and let the guest power itself off.
    case graceful
    /// Resume a paused guest first, then request the graceful shutdown it
    /// cannot receive while paused.
    case resumeThenShutDown
    /// Terminate the virtual machine immediately, losing unsaved guest state.
    case force
}

/// What a clone does with the source VM's machine identity.
public enum CloneMachineIdentity: String, Codable, Sendable, Hashable, CaseIterable {
    /// Follow the app's clone preference.
    case followPreference
    /// Mint a fresh identity, so both VMs can run at once.
    case new
    /// Keep the source's identity, so the clone is the same machine to its
    /// guest — and cannot run beside the source.
    case keep
}

/// What two VMs collide on.
public enum ConflictReason: String, Codable, Sendable, Hashable, CaseIterable {
    case machineIdentity
    case macAddress
}
