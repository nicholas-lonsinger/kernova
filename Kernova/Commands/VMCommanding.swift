import Foundation
import KernovaKit

/// Every VM verb Kernova offers, typed end to end.
///
/// One method per verb, addressing VMs by ``VMSelector`` and refusing with
/// ``CommandError``. Every front door — the AppKit UI, AppleScript, the
/// `kernova://` URL scheme, the CLI, App Intents — reaches VMs through this and
/// nothing else, so they inherit identical addressing, state gates, and consent
/// semantics.
///
/// Consent is a parameter, never a presentation: a destructive verb called
/// without it refuses with ``CommandError/confirmationRequired(_:)`` describing
/// what confirming entails. Implementations present nothing.
///
/// `@MainActor` is a decision, not an accident: library state is UI-adjacent,
/// all VZ work already runs on per-VM `VMSession` actors, and command traffic is
/// human-scale. The `await` at each call site makes the isolation an
/// implementation detail — if it is ever revisited, only the implementation
/// moves.
///
/// A verb that completes synchronously is spelled synchronously. Reserving an
/// import destination is the case that matters: a batch's reservations have to
/// see each other's phantom rows, which one suspension point between them would
/// break.
@MainActor
protocol VMCommanding: AnyObject {
    // MARK: - Reads

    /// Every VM in the library, in the order the sidebar shows them.
    func list() -> [VMSummary]

    func info(_ selector: VMSelector) throws -> VMInfo

    /// The address the app reserved for this guest, `nil` when it has none.
    func ipAddress(of selector: VMSelector) throws -> String?

    /// The VM's named restore points, newest first.
    func snapshots(of selector: VMSelector) throws -> [SnapshotSummary]

    // MARK: - Lifecycle

    /// Starts the VM, running whatever guest setup it still owes first.
    ///
    /// `recovery` cold-boots a stopped macOS guest into macOS Recovery.
    func start(_ selector: VMSelector, recovery: Bool) async throws

    /// Stops the VM the way `disposition` names.
    ///
    /// A live-paused guest cannot receive an ACPI shutdown, so `.graceful`
    /// there refuses for confirmation and offers the two dispositions that can.
    /// `.force` always asks: it discards unsaved guest state.
    func stop(_ selector: VMSelector, disposition: StopDisposition, confirmed: Bool) async throws

    func pause(_ selector: VMSelector) async throws

    func resume(_ selector: VMSelector) async throws

    /// Save-suspends the VM to its bundle's suspend slot.
    func suspend(_ selector: VMSelector) async throws

    /// Shuts the guest down and starts it again once it has powered off.
    func restart(_ selector: VMSelector) async throws

    /// Brings the VM's display to the front — the detached window for a
    /// pop-out or fullscreen VM, else keyboard focus in the inline display.
    func open(_ selector: VMSelector) throws

    // MARK: - Snapshots

    @discardableResult
    func takeSnapshot(_ selector: VMSelector, name: String, notes: String) async throws
        -> SnapshotSummary

    /// Returns the VM to a snapshot, optionally capturing the current state
    /// first so the revert is reversible.
    func revertToSnapshot(
        _ selector: VMSelector, snapshot: UUID, takingCheckpoint: Bool, confirmed: Bool
    ) async throws

    func deleteSnapshot(_ selector: VMSelector, snapshot: UUID, confirmed: Bool) async throws

    func renameSnapshot(_ selector: VMSelector, snapshot: UUID, to newName: String) throws

    func setSnapshotNotes(_ selector: VMSelector, snapshot: UUID, notes: String) throws

    // MARK: - Library

    /// Copies the VM's bundle into a new one, answering the row the copy fills.
    @discardableResult
    func clone(_ selector: VMSelector, machineIdentity: CloneMachineIdentity) throws -> VMSummary

    func rename(_ selector: VMSelector, to newName: String) throws

    /// Deletes the VM's bundle and the external files named in `alsoRemoving`.
    ///
    /// `permanently` bypasses the Trash. Files shared with another VM are never
    /// deleted even when their id is passed.
    func delete(
        _ selector: VMSelector, permanently: Bool, alsoRemoving: Set<UUID>, confirmed: Bool
    ) async throws

    /// Copies a `.kernova` bundle into the library, answering the row the copy
    /// fills — or the existing row when the bundle is already in the library.
    @discardableResult
    func importVM(from url: URL) throws -> VMSummary

    /// Cancels an in-flight clone or import and removes its row.
    func cancelPreparing(_ selector: VMSelector, confirmed: Bool) throws

    // MARK: - Observation

    /// A stream of library changes, for callers that cannot observe the model.
    ///
    /// Each call returns its own stream; ending iteration drops it.
    func events() -> AsyncStream<VMLibraryEvent>
}
