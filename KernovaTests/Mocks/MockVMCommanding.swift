import Foundation
import KernovaKit
import KernovaTestSupport

@testable import Kernova

/// A wait a verb parks in until the task running it is cancelled.
///
/// Lock-guarded and isolation-free rather than `@MainActor`: a cancellation
/// handler is isolated to nothing, and a cancel that lands *before* the park
/// still has to release it.
final class CancellationPark: @unchecked Sendable {
    /// Fires when a park is released, so a test awaits the cancellation rather
    /// than polling for it.
    let released = AsyncGate()

    private let lock = NSLock()
    private var parked: CheckedContinuation<Void, Never>?
    private var cancelled = false

    /// Whether the task that parked here has been cancelled.
    var wasCancelled: Bool { lock.withLock { cancelled } }

    /// Suspends until the calling task is cancelled.
    func park() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let alreadyCancelled = lock.withLock { () -> Bool in
                    guard !cancelled else { return true }
                    parked = continuation
                    return false
                }
                if alreadyCancelled { continuation.resume() }
            }
        } onCancel: {
            release()
        }
    }

    private func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            cancelled = true
            defer { parked = nil }
            return parked
        }
        waiting?.resume()
        released.notify()
    }
}

/// In-memory mock for `VMCommanding` that records what each verb was asked to
/// do without a library, a lifecycle coordinator, or a VM behind it.
///
/// `@MainActor` like the protocol, so no lock is needed: every call arrives on
/// the test's own isolation.
@MainActor
final class MockVMCommanding: VMCommanding {
    // MARK: - Seeding

    /// The library `list()` answers with, and what the recorded verbs address.
    var library: [VMSummary] = []
    /// The address `ipAddress(of:)` answers with.
    var guestAddress: GuestIPAddress = .unavailable
    /// The snapshot `takeSnapshot` answers with, built from its arguments when
    /// left unset.
    var snapshotToReturn: SnapshotSummary?
    /// What `info` answers for a VM, overriding the value synthesized from its
    /// summary — for tests that vary a field the library alone doesn't carry.
    var infoByID: [UUID: VMInfo] = [:]
    /// What `snapshots(of:)` answers per VM.
    var snapshotsByVM: [UUID: [SnapshotSummary]] = [:]
    /// The row `clone` answers with, synthesized from the source when unset.
    var cloneResult: VMSummary?
    /// The row `importVM` answers with, synthesized from the source URL when
    /// unset.
    var importResult: VMSummary?
    /// What `configurationKeys()` answers with.
    var configurationKeyDescriptors: [ConfigurationKeyDescriptor] = []
    /// What `configuration(_:keys:)` answers with.
    var configurationEntries: [ConfigurationEntry] = []
    /// The settled row a waited clone or import answers with; the row it
    /// registered when unset.
    var outcomeResult: VMSummary?
    /// Thrown by a waited clone or import in place of its settled row — the
    /// copy's own failure.
    var outcomeError: (any Error)?
    /// Parks a waited clone or import until its task is cancelled — the verb
    /// still in flight when whoever asked for it goes away.
    var outcomePark: CancellationPark?
    /// Fires as a waited clone or import begins waiting, so a test can act
    /// against a verb that is provably running.
    let outcomeEntered = AsyncGate()
    /// What `snapshotSizes(of:)` answers with.
    var answeredSnapshotSizes: [UUID: SnapshotSize] = [:]
    /// What `sharedDirectories(of:)` answers per VM.
    var sharedDirectoriesByVM: [UUID: [SharedDirectorySummary]] = [:]
    /// What `usbAccessories(of:)` answers per VM.
    var usbAccessoriesByVM: [UUID: [USBAccessorySummary]] = [:]
    /// What `availableUSBAccessories()` answers with.
    var availableUSBAccessoriesToReturn: [USBAccessorySummary] = []
    /// What `usbPairings(of:)` answers with, whichever VM is named.
    var usbPairingsToReturn: [USBPairingSummary] = []
    /// What `externalAttachments(of:)` answers with.
    var externalAttachmentsToReturn: [ExternalAttachment] = []
    /// What `sharingVMNames(_:path:bookmark:)` answers with.
    var sharingVMNamesToReturn: [String] = []
    /// Consulted by `importVM(atPath:)` for the grant, as the core consults its
    /// own; unset, the named path is read as given.
    var sourceAuthority: (any SandboxSourceAuthorizing)?
    /// What `groupAction(_:on:)` answers with, built empty from its arguments
    /// when unset.
    var groupActionReport: VMGroupActionReport?
    /// Thrown by `groupAction(_:on:)` in place of a report.
    var groupActionError: (any Error)?
    /// What `concernedCounts(in:)` answers.
    var concernedCountsToReturn: [VMGroupAction: Int] = [:]

    // MARK: - Recorded calls

    private(set) var listCallCount = 0
    private(set) var infoSelectors: [VMSelector] = []
    private(set) var ipAddressSelectors: [VMSelector] = []
    private(set) var snapshotsSelectors: [VMSelector] = []
    private(set) var snapshotSizesSelectors: [VMSelector] = []
    private(set) var sharedDirectoriesSelectors: [VMSelector] = []
    private(set) var usbAccessoriesSelectors: [VMSelector] = []
    private(set) var availableUSBAccessoriesCallCount = 0
    private(set) var usbPairingsSelectors: [VMSelector?] = []
    private(set) var forgetUSBPairingCalls: [(selector: VMSelector, key: String)] = []
    private(set) var externalAttachmentsSelectors: [VMSelector] = []
    private(set) var sharingVMNamesCalls: [(selector: VMSelector, path: String, bookmark: Data?)] =
        []
    private(set) var removeStartFailedAttachmentCalls: [(selector: VMSelector, attachment: StartFailedAttachment)] = []
    private(set) var startCalls: [(selector: VMSelector, recovery: Bool, consent: Consent)] = []
    private(set) var provideGuestAccountPasswordCalls: [(selector: VMSelector, password: String)] = []
    private(set) var skipGuestAccountSelectors: [VMSelector] = []
    private(set) var stopCalls:
        [(
            selector: VMSelector, disposition: StopDisposition, consent: Consent,
            timeout: TimeInterval?
        )] = []
    private(set) var pauseSelectors: [VMSelector] = []
    private(set) var resumeSelectors: [VMSelector] = []
    /// Each resume's consent, in the order of ``resumeSelectors``.
    private(set) var resumeConsents: [Consent] = []
    /// The MAC address remedy each bring-up verb carried, per verb, in call
    /// order.
    private(set) var startRemedies: [MACAddressRemedy?] = []
    private(set) var resumeRemedies: [MACAddressRemedy?] = []
    private(set) var restartRemedies: [MACAddressRemedy?] = []
    private(set) var revertRemedies: [MACAddressRemedy?] = []
    /// What a bring-up carrying no remedy refuses with, when set.
    var macAddressRemedyPrompt: MACAddressRemedyPrompt?
    private(set) var suspendSelectors: [VMSelector] = []
    private(set) var restartCalls: [(selector: VMSelector, timeout: TimeInterval?)] = []
    /// Each restart's consent, in the order of ``restartCalls``.
    private(set) var restartConsents: [Consent] = []
    private(set) var openSelectors: [VMSelector] = []
    private(set) var revealSelectors: [VMSelector] = []
    private(set) var showInFinderSelectors: [VMSelector] = []
    private(set) var cancelGuestSetupCalls: [(selector: VMSelector, consent: Consent)] = []
    private(set) var takeSnapshotCalls: [(selector: VMSelector, name: String, notes: String)] = []
    private(set) var revertCalls: [(selector: VMSelector, snapshot: UUID, takingCheckpoint: Bool, consent: Consent)] =
        []
    private(set) var deleteSnapshotCalls: [(selector: VMSelector, snapshot: UUID, consent: Consent)] =
        []
    private(set) var renameSnapshotCalls: [(selector: VMSelector, snapshot: UUID, newName: String)] =
        []
    private(set) var setSnapshotNotesCalls: [(selector: VMSelector, snapshot: UUID, notes: String)] =
        []
    private(set) var createCalls:
        [(configuration: VMConfiguration, startAfterCreate: Bool, guestAccountPassword: String?)] =
            []
    private(set) var cloneCalls: [(selector: VMSelector, outcome: CloneOutcome?, waitForOutcome: Bool)] =
        []
    private(set) var renameCalls: [(selector: VMSelector, newName: String)] = []
    private(set) var deleteCalls:
        [(selector: VMSelector, permanently: Bool, alsoRemoving: Set<UUID>, consent: Consent)] = []
    private(set) var importURLs: [URL] = []
    /// Each import's `waitForOutcome`, in the order of ``importURLs``.
    private(set) var importWaits: [Bool] = []
    private(set) var cancelPreparingCalls: [(selector: VMSelector, consent: Consent)] = []
    private(set) var attachStorageDiskCalls: [(selector: VMSelector, files: [PickedFile])] = []
    private(set) var createStorageDiskCalls: [(selector: VMSelector, sizeInGB: Int)] = []
    private(set) var removeStorageDiskCalls: [(selector: VMSelector, disk: UUID, trashFile: Bool, consent: Consent)] =
        []
    private(set) var renameStorageDiskCalls: [(selector: VMSelector, disk: UUID, newLabel: String)] =
        []
    private(set) var setStorageDiskNotesCalls: [(selector: VMSelector, disk: UUID, notes: String)] =
        []
    private(set) var setStorageDiskReadOnlyCalls: [(selector: VMSelector, disk: UUID, readOnly: Bool)] = []
    private(set) var reorderStorageDisksCalls: [(selector: VMSelector, order: [UUID])] = []
    private(set) var attachRemovableMediaCalls: [(selector: VMSelector, files: [PickedFile])] = []
    private(set) var createRemovableMediaCalls: [(selector: VMSelector, sizeInGB: Int, destinationURL: URL)] = []
    private(set) var removeRemovableMediaCalls:
        [(selector: VMSelector, item: UUID, trashFile: Bool, consent: Consent)] =
            []
    private(set) var ejectRemovableMediaCalls: [(selector: VMSelector, item: UUID)] = []
    private(set) var renameRemovableMediaCalls: [(selector: VMSelector, item: UUID, newLabel: String)] = []
    private(set) var setRemovableMediaNotesCalls: [(selector: VMSelector, item: UUID, notes: String)] = []
    private(set) var setRemovableMediaReadOnlyCalls: [(selector: VMSelector, item: UUID, readOnly: Bool)] = []
    private(set) var addSharedDirectoriesCalls: [(selector: VMSelector, files: [PickedFile])] = []
    private(set) var addSharedDirectoryCalls: [(selector: VMSelector, path: String, readOnly: Bool)] = []
    private(set) var removeSharedDirectoryCalls: [(selector: VMSelector, directory: UUID)] = []
    private(set) var removeSharedDirectoryPathCalls: [(selector: VMSelector, path: String)] = []
    private(set) var attachUSBAccessoryCalls: [(selector: VMSelector, accessory: UInt64)] = []
    private(set) var detachUSBAccessoryCalls: [(selector: VMSelector, device: UUID)] = []
    private(set) var configurationCalls: [(selector: VMSelector, keys: [String]?)] = []
    private(set) var setConfigurationCalls:
        [(selector: VMSelector, assignments: [ConfigurationEntry], consent: Consent)] = []
    private(set) var configurationKeysCallCount = 0
    private(set) var setSharedDirectoryReadOnlyCalls: [(selector: VMSelector, directory: UUID, readOnly: Bool)] = []
    private(set) var mountGuestAgentDiskSelectors: [VMSelector] = []
    private(set) var unmountGuestAgentDiskSelectors: [VMSelector] = []

    // MARK: - Error injection

    var infoError: (any Error)?
    var configurationError: (any Error)?
    var setConfigurationError: (any Error)?
    var ipAddressError: (any Error)?
    var snapshotsError: (any Error)?
    var snapshotSizesError: (any Error)?
    var sharedDirectoriesError: (any Error)?
    var usbAccessoriesError: (any Error)?
    var availableUSBAccessoriesError: (any Error)?
    var usbPairingsError: (any Error)?
    var forgetUSBPairingError: (any Error)?
    var usbAccessoryEditError: (any Error)?
    var externalAttachmentsError: (any Error)?
    var sharingVMNamesError: (any Error)?
    var startError: (any Error)?
    /// What a start of a VM still owing an account answer refuses with,
    /// mirroring the core's own gate; `nil` leaves the account out of the
    /// picture entirely. Cleared by either answering verb, so the loop's second
    /// pass gets through exactly as it does against the core.
    var guestAccountPrompt: GuestAccountPrompt?
    /// What ``provideGuestAccountPassword(_:password:)`` refuses with — the
    /// password macOS turned down, for a door that has no validator of its own.
    var provideGuestAccountPasswordError: (any Error)?
    var skipGuestAccountError: (any Error)?
    var removeStartFailedAttachmentError: (any Error)?
    var stopError: (any Error)?
    var pauseError: (any Error)?
    var resumeError: (any Error)?
    var suspendError: (any Error)?
    var restartError: (any Error)?
    var openError: (any Error)?
    var revealError: (any Error)?
    var showInFinderError: (any Error)?
    var cancelGuestSetupError: (any Error)?
    var takeSnapshotError: (any Error)?
    var revertError: (any Error)?
    var deleteSnapshotError: (any Error)?
    var renameSnapshotError: (any Error)?
    var setSnapshotNotesError: (any Error)?
    var createError: (any Error)?
    var cloneError: (any Error)?
    var renameError: (any Error)?
    var deleteError: (any Error)?
    var importError: (any Error)?
    var cancelPreparingError: (any Error)?
    var storageDiskEditError: (any Error)?
    var removableMediaEditError: (any Error)?
    var sharedDirectoryEditError: (any Error)?
    var guestAgentDiskError: (any Error)?

    /// Refuses `stop` until its consent covers the prompt's kind, then succeeds —
    /// the consent round trip every destructive verb performs.
    var stopConsentPrompt: ConfirmationPrompt?
    /// The same round trip for `start`, raised before the account question as
    /// the core's admission is.
    var startConsentPrompt: ConfirmationPrompt?
    /// The same round trip for `resume`.
    var resumeConsentPrompt: ConfirmationPrompt?
    /// The same round trip for `restart`.
    var restartConsentPrompt: ConfirmationPrompt?
    /// The same round trip for `revertToSnapshot`.
    var revertConsentPrompt: ConfirmationPrompt?
    /// The same round trip for `deleteSnapshot`.
    var deleteSnapshotConsentPrompt: ConfirmationPrompt?
    /// The same round trip for `delete`.
    var deleteConsentPrompt: ConfirmationPrompt?
    /// The same round trip for `cancelPreparing`.
    var cancelPreparingConsentPrompt: ConfirmationPrompt?
    /// The same round trip for `cancelGuestSetup`.
    var cancelGuestSetupConsentPrompt: ConfirmationPrompt?
    /// The same round trip for a trashing attachment removal.
    var removeAttachmentConsentPrompt: ConfirmationPrompt?

    /// What `mountGuestAgentDisk` answers with.
    var guestAgentDiskMountOutcome: GuestAgentDiskMountOutcome = .attached(.usb)

    // MARK: - Events

    private let eventStream = AsyncStream<[VMLibraryEvent]>.makeStream()

    /// Publishes one batch of library events to whoever is reading `events()`.
    func emit(_ events: [VMLibraryEvent]) {
        eventStream.continuation.yield(events)
    }

    /// Publishes `event` as a batch of one.
    func emit(_ event: VMLibraryEvent) {
        emit([event])
    }

    // MARK: - Reads

    /// Lists ``library`` whatever the selection.
    func list(_ selection: VMLibrarySelection) -> [VMSummary] {
        listCallCount += 1
        return library
    }

    /// Every query `selection(for:verb:)` was asked to resolve.
    private(set) var selectionQueries: [VMListQuery] = []
    /// What `groups()` answers with.
    var groupsToReturn: [GroupSummary] = []

    func selection(for query: VMListQuery, verb: VMVerb) throws -> VMLibrarySelection {
        selectionQueries.append(query)
        return .all
    }

    func groups() throws -> [GroupSummary] { groupsToReturn }

    func info(_ selector: VMSelector) throws -> VMInfo {
        infoSelectors.append(selector)
        if let infoError { throw infoError }
        let summary = try resolve(selector)
        if let seeded = infoByID[summary.id] { return seeded }
        return VMInfo(
            id: summary.id,
            name: summary.name,
            status: summary.status,
            guestOS: "linux",
            cpuCount: 2,
            memoryBytes: 4 << 30,
            diskSizeInGB: 64,
            networkMode: nil,
            networkMembership: nil,
            networkName: nil,
            macAddress: nil,
            ipAddress: guestAddress,
            agentStatus: "notInstalled",
            hasSavedState: false,
            isEphemeral: false,
            snapshotCount: 0, hasSnapshots: false, guestAgent: nil,
            stateBucket: .stopped,
            bundlePath: "/tmp/\(summary.id.uuidString).kernova", heldByAnotherCopy: false)
    }

    func ipAddress(of selector: VMSelector) throws -> GuestIPAddress {
        ipAddressSelectors.append(selector)
        if let ipAddressError { throw ipAddressError }
        _ = try resolve(selector)
        return guestAddress
    }

    func snapshots(of selector: VMSelector) throws -> [SnapshotSummary] {
        snapshotsSelectors.append(selector)
        if let snapshotsError { throw snapshotsError }
        return snapshotsByVM[try resolve(selector).id] ?? []
    }

    func snapshotSizes(of selector: VMSelector) async throws -> [UUID: SnapshotSize] {
        snapshotSizesSelectors.append(selector)
        if let snapshotSizesError { throw snapshotSizesError }
        _ = try resolve(selector)
        return answeredSnapshotSizes
    }

    func sharedDirectories(of selector: VMSelector) throws -> [SharedDirectorySummary] {
        sharedDirectoriesSelectors.append(selector)
        if let sharedDirectoriesError { throw sharedDirectoriesError }
        return sharedDirectoriesByVM[try resolve(selector).id] ?? []
    }

    func usbAccessories(of selector: VMSelector) throws -> [USBAccessorySummary] {
        usbAccessoriesSelectors.append(selector)
        if let usbAccessoriesError { throw usbAccessoriesError }
        return usbAccessoriesByVM[try resolve(selector).id] ?? []
    }

    func availableUSBAccessories() throws -> [USBAccessorySummary] {
        availableUSBAccessoriesCallCount += 1
        if let availableUSBAccessoriesError { throw availableUSBAccessoriesError }
        return availableUSBAccessoriesToReturn
    }

    func usbPairings(of selector: VMSelector?) throws -> [USBPairingSummary] {
        usbPairingsSelectors.append(selector)
        if let usbPairingsError { throw usbPairingsError }
        if let selector { _ = try resolve(selector) }
        return usbPairingsToReturn
    }

    func forgetUSBPairing(_ selector: VMSelector, key: String) throws {
        forgetUSBPairingCalls.append((selector, key))
        if let forgetUSBPairingError { throw forgetUSBPairingError }
        _ = try resolve(selector)
    }

    func externalAttachments(of selector: VMSelector) async throws -> [ExternalAttachment] {
        externalAttachmentsSelectors.append(selector)
        if let externalAttachmentsError { throw externalAttachmentsError }
        _ = try resolve(selector)
        return externalAttachmentsToReturn
    }

    func sharingVMNames(_ selector: VMSelector, path: String, bookmark: Data?) async throws
        -> [String]
    {
        sharingVMNamesCalls.append((selector, path, bookmark))
        if let sharingVMNamesError { throw sharingVMNamesError }
        _ = try resolve(selector)
        return sharingVMNamesToReturn
    }

    // MARK: - Lifecycle

    func start(
        _ selector: VMSelector, recovery: Bool, consent: Consent,
        macAddressRemedy: MACAddressRemedy?
    ) async throws {
        startCalls.append((selector, recovery, consent))
        startRemedies.append(macAddressRemedy)
        try refuseUnremediedMACAddress(macAddressRemedy)
        if let startConsentPrompt, !consent.covers(startConsentPrompt.kind) {
            throw CommandError.confirmationRequired(startConsentPrompt)
        }
        if let guestAccountPrompt, !recovery {
            throw CommandError.guestAccountPasswordRequired(guestAccountPrompt)
        }
        if let startError { throw startError }
    }

    func removeStartFailedAttachment(
        _ selector: VMSelector, attachment: StartFailedAttachment
    ) async throws {
        removeStartFailedAttachmentCalls.append((selector, attachment))
        if let removeStartFailedAttachmentError { throw removeStartFailedAttachmentError }
    }

    func provideGuestAccountPassword(_ selector: VMSelector, password: String) throws {
        provideGuestAccountPasswordCalls.append((selector, password))
        if let provideGuestAccountPasswordError { throw provideGuestAccountPasswordError }
        guestAccountPrompt = nil
    }

    func skipGuestAccount(_ selector: VMSelector) throws {
        skipGuestAccountSelectors.append(selector)
        if let skipGuestAccountError { throw skipGuestAccountError }
        guestAccountPrompt = nil
    }

    func cancelGuestSetup(_ selector: VMSelector, consent: Consent) throws {
        cancelGuestSetupCalls.append((selector, consent))
        if let cancelGuestSetupError { throw cancelGuestSetupError }
        if let cancelGuestSetupConsentPrompt, !consent.covers(cancelGuestSetupConsentPrompt.kind) {
            throw CommandError.confirmationRequired(cancelGuestSetupConsentPrompt)
        }
    }

    func stop(
        _ selector: VMSelector, disposition: StopDisposition, consent: Consent,
        timeout: TimeInterval?
    ) async throws {
        stopCalls.append((selector, disposition, consent, timeout))
        if let stopError { throw stopError }
        if let stopConsentPrompt, !consent.covers(stopConsentPrompt.kind) {
            throw CommandError.confirmationRequired(stopConsentPrompt)
        }
    }

    func pause(_ selector: VMSelector) async throws {
        pauseSelectors.append(selector)
        if let pauseError { throw pauseError }
    }

    func resume(
        _ selector: VMSelector, consent: Consent, macAddressRemedy: MACAddressRemedy?
    ) async throws {
        resumeSelectors.append(selector)
        resumeConsents.append(consent)
        resumeRemedies.append(macAddressRemedy)
        try refuseUnremediedMACAddress(macAddressRemedy)
        if let resumeConsentPrompt, !consent.covers(resumeConsentPrompt.kind) {
            throw CommandError.confirmationRequired(resumeConsentPrompt)
        }
        if let resumeError { throw resumeError }
    }

    func suspend(_ selector: VMSelector) async throws {
        suspendSelectors.append(selector)
        if let suspendError { throw suspendError }
    }

    /// Every group action asked for, in call order.
    private(set) var groupActionCalls: [(action: VMGroupAction, group: VMGroupReference)] = []

    func concernedCounts(in group: VMGroupReference) throws -> [VMGroupAction: Int] {
        if let groupActionError { throw groupActionError }
        return concernedCountsToReturn
    }

    func groupAction(_ action: VMGroupAction, on group: VMGroupReference) async throws -> VMGroupActionReport {
        groupActionCalls.append((action, group))
        if let groupActionError { throw groupActionError }
        return groupActionReport
            ?? VMGroupActionReport(
                action: action, groupKind: group.kind, groupID: UUID(), groupName: group.name, results: [])
    }

    func restart(
        _ selector: VMSelector, timeout: TimeInterval?, consent: Consent,
        macAddressRemedy: MACAddressRemedy?
    ) async throws {
        restartCalls.append((selector, timeout))
        restartConsents.append(consent)
        restartRemedies.append(macAddressRemedy)
        try refuseUnremediedMACAddress(macAddressRemedy)
        if let restartConsentPrompt, !consent.covers(restartConsentPrompt.kind) {
            throw CommandError.confirmationRequired(restartConsentPrompt)
        }
        if let restartError { throw restartError }
    }

    /// Asks the request's requester once it would surface, as the core does.
    func open(_ selector: VMSelector) throws {
        openSelectors.append(selector)
        if let openError { throw openError }
        ActivationRequester.requestActivation()
    }

    /// Asks the request's requester once it would surface, as the core does.
    func reveal(_ selector: VMSelector) throws {
        revealSelectors.append(selector)
        if let revealError { throw revealError }
        ActivationRequester.requestActivation()
    }

    func showInFinder(_ selector: VMSelector) throws {
        showInFinderSelectors.append(selector)
        if let showInFinderError { throw showInFinderError }
        _ = try resolve(selector)
    }

    // MARK: - Snapshots

    func takeSnapshot(
        _ selector: VMSelector, name: String, notes: String, asEphemeralBaseline: Bool
    ) async throws -> SnapshotSummary {
        takeSnapshotCalls.append((selector, name, notes))
        if let takeSnapshotError { throw takeSnapshotError }
        return snapshotToReturn
            ?? SnapshotSummary(
                id: UUID(), name: name, notes: notes, kind: "cold", createdAt: Date(),
                isCurrent: true, isEphemeralBaseline: false)
    }

    func revertToSnapshot(
        _ selector: VMSelector, snapshot: UUID, takingCheckpoint: Bool, consent: Consent,
        macAddressRemedy: MACAddressRemedy?
    ) async throws {
        revertCalls.append((selector, snapshot, takingCheckpoint, consent))
        revertRemedies.append(macAddressRemedy)
        if let revertError { throw revertError }
        if let revertConsentPrompt, !consent.covers(revertConsentPrompt.kind) {
            throw CommandError.confirmationRequired(revertConsentPrompt)
        }
        try refuseUnremediedMACAddress(macAddressRemedy)
    }

    /// Refuses a bring-up carrying no remedy with ``macAddressRemedyPrompt``.
    private func refuseUnremediedMACAddress(_ remedy: MACAddressRemedy?) throws {
        guard remedy == nil, let macAddressRemedyPrompt else { return }
        throw CommandError.macAddressRemedyRequired(macAddressRemedyPrompt)
    }

    func deleteSnapshot(_ selector: VMSelector, snapshot: UUID, consent: Consent) async throws {
        deleteSnapshotCalls.append((selector, snapshot, consent))
        if let deleteSnapshotError { throw deleteSnapshotError }
        if let deleteSnapshotConsentPrompt, !consent.covers(deleteSnapshotConsentPrompt.kind) {
            throw CommandError.confirmationRequired(deleteSnapshotConsentPrompt)
        }
    }

    func renameSnapshot(_ selector: VMSelector, snapshot: UUID, to newName: String) throws {
        renameSnapshotCalls.append((selector, snapshot, newName))
        if let renameSnapshotError { throw renameSnapshotError }
    }

    func setSnapshotNotes(_ selector: VMSelector, snapshot: UUID, notes: String) throws {
        setSnapshotNotesCalls.append((selector, snapshot, notes))
        if let setSnapshotNotesError { throw setSnapshotNotesError }
    }

    // MARK: - Library

    func create(
        configuration: VMConfiguration, startAfterCreate: Bool,
        guestAccountPassword: String?
    ) throws -> VMSummary {
        createCalls.append((configuration, startAfterCreate, guestAccountPassword))
        if let createError { throw createError }
        // The core registers the new VM's phantom row before answering, so a
        // caller that reads it back on the same turn finds it.
        let created = VMSummary(
            id: configuration.id, name: configuration.name,
            status: VMStatus.preparingWireName, ipAddress: .unavailable, heldByAnotherCopy: false)
        library.append(created)
        return created
    }

    func clone(
        _ selector: VMSelector, outcome: CloneOutcome?, waitForOutcome: Bool
    ) async throws -> VMSummary {
        let copy = try registerClone(
            selector, outcome: outcome, waitForOutcome: waitForOutcome)
        return waitForOutcome ? try await self.outcome(of: copy) : copy
    }

    func beginClone(
        _ selector: VMSelector, outcome: CloneOutcome?
    ) throws -> VMSummary {
        try registerClone(selector, outcome: outcome, waitForOutcome: false)
    }

    private func registerClone(
        _ selector: VMSelector, outcome: CloneOutcome?, waitForOutcome: Bool
    ) throws -> VMSummary {
        cloneCalls.append((selector, outcome, waitForOutcome))
        if let cloneError { throw cloneError }
        let source = try resolve(selector)
        let copy =
            cloneResult
            ?? VMSummary(
                id: UUID(), name: "\(source.name) copy", status: source.status, ipAddress: .unavailable,
                heldByAnotherCopy: false)
        // The core registers the copy's arrival before it first suspends, so a
        // caller that reads it back on the same turn finds it.
        library.append(copy)
        return copy
    }

    /// What a waited clone or import answers once its copy settles.
    private func outcome(of registered: VMSummary) async throws -> VMSummary {
        outcomeEntered.notify()
        if let outcomePark { await outcomePark.park() }
        if let outcomeError { throw outcomeError }
        return outcomeResult ?? registered
    }

    func rename(_ selector: VMSelector, to newName: String) throws {
        renameCalls.append((selector, newName))
        if let renameError { throw renameError }
    }

    func delete(
        _ selector: VMSelector, permanently: Bool, alsoRemoving: Set<UUID>, consent: Consent
    ) async throws {
        deleteCalls.append((selector, permanently, alsoRemoving, consent))
        if let deleteError { throw deleteError }
        if let deleteConsentPrompt, !consent.covers(deleteConsentPrompt.kind) {
            throw CommandError.confirmationRequired(deleteConsentPrompt)
        }
    }

    func importVM(atPath path: String, waitForOutcome: Bool) async throws -> VMSummary {
        let named = URL(fileURLWithPath: path)
        guard let sourceAuthority else {
            return try await importVM(from: named, waitForOutcome: waitForOutcome)
        }
        return try await importVM(
            from: try await sourceAuthority.readableURL(for: named, as: .vmBundle),
            waitForOutcome: waitForOutcome)
    }

    func importVM(from url: URL, waitForOutcome: Bool) async throws -> VMSummary {
        let imported = try registerImport(from: url, waitForOutcome: waitForOutcome)
        return waitForOutcome ? try await outcome(of: imported) : imported
    }

    func beginImport(from url: URL) throws -> VMSummary {
        try registerImport(from: url, waitForOutcome: false)
    }

    private func registerImport(from url: URL, waitForOutcome: Bool) throws -> VMSummary {
        importURLs.append(url)
        importWaits.append(waitForOutcome)
        if let importError { throw importError }
        let imported =
            importResult
            ?? VMSummary(
                id: UUID(), name: url.deletingPathExtension().lastPathComponent,
                status: VMStatus.preparingWireName, ipAddress: .unavailable, heldByAnotherCopy: false)
        // The core registers the import's arrival before it first suspends, so
        // a caller that reads it back on the same turn finds it.
        library.append(imported)
        return imported
    }

    func cancelPreparing(_ selector: VMSelector, consent: Consent) throws {
        cancelPreparingCalls.append((selector, consent))
        if let cancelPreparingError { throw cancelPreparingError }
        if let cancelPreparingConsentPrompt, !consent.covers(cancelPreparingConsentPrompt.kind) {
            throw CommandError.confirmationRequired(cancelPreparingConsentPrompt)
        }
    }

    // MARK: - Attachments

    func attachStorageDisks(_ selector: VMSelector, paths files: [PickedFile]) throws {
        attachStorageDiskCalls.append((selector, files))
        if let storageDiskEditError { throw storageDiskEditError }
    }

    func createStorageDisk(_ selector: VMSelector, sizeInGB: Int) async throws {
        createStorageDiskCalls.append((selector, sizeInGB))
        if let storageDiskEditError { throw storageDiskEditError }
    }

    func removeStorageDisk(
        _ selector: VMSelector, disk: UUID, trashFile: Bool, consent: Consent
    ) async throws {
        removeStorageDiskCalls.append((selector, disk, trashFile, consent))
        if let storageDiskEditError { throw storageDiskEditError }
        if let removeAttachmentConsentPrompt, trashFile, !consent.covers(removeAttachmentConsentPrompt.kind) {
            throw CommandError.confirmationRequired(removeAttachmentConsentPrompt)
        }
    }

    func renameStorageDisk(_ selector: VMSelector, disk: UUID, to newLabel: String) throws {
        renameStorageDiskCalls.append((selector, disk, newLabel))
        if let storageDiskEditError { throw storageDiskEditError }
    }

    func setStorageDiskNotes(_ selector: VMSelector, disk: UUID, notes: String) throws {
        setStorageDiskNotesCalls.append((selector, disk, notes))
        if let storageDiskEditError { throw storageDiskEditError }
    }

    func setStorageDiskReadOnly(_ selector: VMSelector, disk: UUID, readOnly: Bool) throws {
        setStorageDiskReadOnlyCalls.append((selector, disk, readOnly))
        if let storageDiskEditError { throw storageDiskEditError }
    }

    func reorderStorageDisks(_ selector: VMSelector, order: [UUID]) throws {
        reorderStorageDisksCalls.append((selector, order))
        if let storageDiskEditError { throw storageDiskEditError }
    }

    func attachRemovableMedia(_ selector: VMSelector, paths files: [PickedFile]) throws {
        attachRemovableMediaCalls.append((selector, files))
        if let removableMediaEditError { throw removableMediaEditError }
    }

    func createRemovableMedia(
        _ selector: VMSelector, sizeInGB: Int, destinationURL: URL
    ) async throws {
        createRemovableMediaCalls.append((selector, sizeInGB, destinationURL))
        if let removableMediaEditError { throw removableMediaEditError }
    }

    func removeRemovableMedia(
        _ selector: VMSelector, item: UUID, trashFile: Bool, consent: Consent
    ) async throws {
        removeRemovableMediaCalls.append((selector, item, trashFile, consent))
        if let removableMediaEditError { throw removableMediaEditError }
        if let removeAttachmentConsentPrompt, trashFile, !consent.covers(removeAttachmentConsentPrompt.kind) {
            throw CommandError.confirmationRequired(removeAttachmentConsentPrompt)
        }
    }

    func ejectRemovableMedia(_ selector: VMSelector, item: UUID) throws {
        ejectRemovableMediaCalls.append((selector, item))
        if let removableMediaEditError { throw removableMediaEditError }
    }

    func renameRemovableMedia(_ selector: VMSelector, item: UUID, to newLabel: String) throws {
        renameRemovableMediaCalls.append((selector, item, newLabel))
        if let removableMediaEditError { throw removableMediaEditError }
    }

    func setRemovableMediaNotes(_ selector: VMSelector, item: UUID, notes: String) throws {
        setRemovableMediaNotesCalls.append((selector, item, notes))
        if let removableMediaEditError { throw removableMediaEditError }
    }

    func setRemovableMediaReadOnly(_ selector: VMSelector, item: UUID, readOnly: Bool) throws {
        setRemovableMediaReadOnlyCalls.append((selector, item, readOnly))
        if let removableMediaEditError { throw removableMediaEditError }
    }

    func addSharedDirectories(_ selector: VMSelector, paths files: [PickedFile]) throws {
        addSharedDirectoriesCalls.append((selector, files))
        if let sharedDirectoryEditError { throw sharedDirectoryEditError }
    }

    func addSharedDirectory(_ selector: VMSelector, path: String, readOnly: Bool) async throws {
        addSharedDirectoryCalls.append((selector, path, readOnly))
        if let sharedDirectoryEditError { throw sharedDirectoryEditError }
    }

    func removeSharedDirectory(_ selector: VMSelector, directory: UUID) throws {
        removeSharedDirectoryCalls.append((selector, directory))
        if let sharedDirectoryEditError { throw sharedDirectoryEditError }
    }

    func removeSharedDirectory(_ selector: VMSelector, path: String) throws {
        removeSharedDirectoryPathCalls.append((selector, path))
        if let sharedDirectoryEditError { throw sharedDirectoryEditError }
    }

    func setSharedDirectoryReadOnly(
        _ selector: VMSelector, directory: UUID, readOnly: Bool
    ) throws {
        setSharedDirectoryReadOnlyCalls.append((selector, directory, readOnly))
        if let sharedDirectoryEditError { throw sharedDirectoryEditError }
    }

    // MARK: - USB Accessories

    func attachUSBAccessory(_ selector: VMSelector, accessory: UInt64) async throws {
        attachUSBAccessoryCalls.append((selector, accessory))
        if let usbAccessoryEditError { throw usbAccessoryEditError }
    }

    func detachUSBAccessory(_ selector: VMSelector, device: UUID) async throws {
        detachUSBAccessoryCalls.append((selector, device))
        if let usbAccessoryEditError { throw usbAccessoryEditError }
    }

    // MARK: - Configuration

    func configurationKeys() -> [ConfigurationKeyDescriptor] {
        configurationKeysCallCount += 1
        return configurationKeyDescriptors
    }

    func configuration(_ selector: VMSelector, keys: [String]?) throws -> [ConfigurationEntry] {
        configurationCalls.append((selector, keys))
        if let configurationError { throw configurationError }
        return configurationEntries
    }

    @discardableResult
    func setConfiguration(
        _ selector: VMSelector, assignments: [ConfigurationEntry], consent: Consent
    ) throws -> [ConfigurationEntry] {
        setConfigurationCalls.append((selector, assignments, consent))
        if let setConfigurationError { throw setConfigurationError }
        return assignments
    }

    func mountGuestAgentDisk(_ selector: VMSelector) throws -> GuestAgentDiskMountOutcome {
        mountGuestAgentDiskSelectors.append(selector)
        if let guestAgentDiskError { throw guestAgentDiskError }
        return guestAgentDiskMountOutcome
    }

    func unmountGuestAgentDisk(_ selector: VMSelector) throws {
        unmountGuestAgentDiskSelectors.append(selector)
        if let guestAgentDiskError { throw guestAgentDiskError }
    }

    // MARK: - Application

    /// How many times the quit verb was asked for.
    private(set) var quitCallCount = 0

    func quit() {
        quitCallCount += 1
    }

    // MARK: - Networks

    var networksToReturn: [NetworkSummary] = []
    /// Thrown by every network edit when set.
    var networkError: (any Error)?
    private(set) var createNetworkCalls: [(name: String, kind: NetworkKind)] = []
    private(set) var renameNetworkCalls: [(network: String, newName: String)] = []
    private(set) var deleteNetworkCalls: [String] = []

    func networks() -> [NetworkSummary] { networksToReturn }

    func createNetwork(name: String, kind: NetworkKind) throws -> NetworkSummary {
        createNetworkCalls.append((name, kind))
        if let networkError { throw networkError }
        let network = NetworkSummary(id: UUID(), name: name, kind: kind, members: [])
        networksToReturn.append(network)
        return network
    }

    func renameNetwork(_ network: String, to newName: String) throws {
        renameNetworkCalls.append((network, newName))
        if let networkError { throw networkError }
    }

    func deleteNetwork(_ network: String) throws {
        deleteNetworkCalls.append(network)
        if let networkError { throw networkError }
    }

    // MARK: - Observation

    /// One stream shared by every call, unlike the core's per-caller streams:
    /// the doubles here drive a single subscriber.
    func events() -> AsyncStream<[VMLibraryEvent]> { eventStream.stream }

    // MARK: - Resolution

    /// The one VM `selector` names, by the same rules the core follows.
    private func resolve(_ selector: VMSelector) throws -> VMSummary {
        let matches: [VMSummary] =
            switch selector {
            case .id(let id): library.filter { $0.id == id }
            case .name(let name): library.filter { $0.name == name }
            case .idOrName(let text):
                library.filter { $0.id.uuidString == text || $0.name == text }
            }
        guard let only = matches.first else { throw CommandError.notFound(selector) }
        guard matches.count == 1 else {
            throw CommandError.ambiguous(selector: selector, candidates: matches)
        }
        return only
    }
}
