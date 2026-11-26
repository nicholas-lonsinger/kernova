import Foundation
import KernovaAgentHost
import KernovaCommandModel
import Synchronization
import Testing

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore
@testable import KernovaKit

// `waitForChange` below is here rather than in KernovaTestSupport: it is built
// on the core's `waitForObservedChange`, and only the core's and the app's
// tests wait on `@Observable` production state — the GuestAgent/KernovaKit
// bundles' predicates read `Sendable` boxes (`AtomicInt`, `AtomicBox`) with no
// such observable type to track.

// MARK: - In-memory defaults

/// Wraps `makeTestDefaults` (`KernovaTestSupport`) in an `AppPreferences`, for
/// suites that only need the typed wrapper (e.g. to construct a
/// `VMLibraryViewModel`) and never inspect the raw `UserDefaults` store
/// directly.
func makeTestPreferences() -> AppPreferences {
    AppPreferences(defaults: makeTestDefaults())
}

// MARK: - Library construction

/// A `VMLifecycleCoordinator` over mocks — the test target's one construction
/// of one, which a test library is built on too.
///
/// A Downloads folder of the running test case's own, which holds nothing until
/// the test puts it there.
func makeTestDownloadsDirectory() -> URL {
    TestScratchDirectory(prefix: "Downloads").url
}

/// Downloads is the test case's own folder unless a test names one, never the
/// user's.
@MainActor
func makeTestLifecycle(
    virtualization: any VirtualizationProviding = MockVirtualizationService(),
    installService: any MacOSInstallProviding = MockMacOSInstallService(),
    ipswService: any IPSWProviding = MockIPSWService(),
    removableMedia: any RemovableMediaAttaching = MockRemovableMediaDeviceService(),
    usbAccessoryPassthrough: USBAccessoryPassthrough = .unavailable(.needsEntitlement),
    linuxImageResolveService: any LinuxImageResolving = MockLinuxImageResolveService(),
    downloadService: any Downloading = MockDownloadService(),
    fileSystem: MockFileSystem = MockFileSystem(),
    downloadsDirectory: URL = makeTestDownloadsDirectory()
) -> VMLifecycleCoordinator {
    VMLifecycleCoordinator(
        virtualizationService: virtualization,
        installService: installService,
        ipswService: ipswService,
        removableMediaDeviceService: removableMedia,
        usbAccessoryPassthrough: usbAccessoryPassthrough,
        linuxImageResolveService: linuxImageResolveService,
        downloadService: downloadService,
        fileSystem: fileSystem,
        downloadsDirectory: downloadsDirectory)
}

/// A real `VMLibrary` over mocks: the test target's one construction of a
/// library, and what a test changes a VM's configuration through once the VM
/// exists, since only the library writes it. Its VMs come from
/// ``VMLibrary/registerFixture(name:guestOS:phase:preferences:hostState:snapshots:pairings:files:agentConnector:mutate:)``.
///
/// The caller keeps the library alive for as long as it edits: each instance
/// reaches it weakly.
@MainActor
func makeWiredLibrary(
    storage: MockVMStorageService = MockVMStorageService(),
    machineFiles: (any VMBundleMachineFileWorking)? = nil,
    lifecycle: VMLifecycleCoordinator? = nil,
    fileSystem: MockFileSystem = MockFileSystem(),
    preferences: AppPreferences = makeTestPreferences(),
    vmnetNetworks: VmnetNetworkService = .scripted(),
    arpTable: ScriptedARPTable = ScriptedARPTable(),
    entitlements: EntitlementService = .entitled,
    networks: VMNetworkDirectory = VMNetworkDirectory(fileURL: nil),
    organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil),
    guestAccountPasswords: any GuestAccountPasswordStoring = InMemoryGuestAccountPasswordStore(),
    bridgedInterfaces: any BridgedInterfaceProviding = MockBridgedInterfaceProvider(),
    appActivation: HostNotification = HostNotifications.isolated().appDidBecomeActive,
    hostPasteboard: any ClipboardPasteboard = FakePasteboard(),
    bundleProducts: AppBundleProducts = .testing,
    virtualizationHost: any VirtualizationHostProviding = FakeVirtualizationHost()
) -> VMLibrary {
    let library = VMLibrary(
        storageService: storage,
        machineFiles: machineFiles ?? MockVMBundleMachineFiles(files: storage.files),
        lifecycle: lifecycle ?? makeTestLifecycle(fileSystem: fileSystem),
        preferences: preferences,
        vmnetNetworks: vmnetNetworks,
        arpTable: arpTable,
        entitlements: entitlements,
        networks: networks,
        organization: organization,
        guestAccountPasswords: guestAccountPasswords,
        virtualizationHost: virtualizationHost,
        bridgedInterfaces: bridgedInterfaces,
        appActivation: appActivation,
        hostPasteboard: hostPasteboard,
        bundleProducts: bundleProducts)
    return library
}

extension HostNotifications {
    /// Host notifications posted into a center of the test's own, so a post
    /// reaches only the fixture built with them — never every live observer in
    /// the test host, as a post into the app's own centers would.
    static func isolated() -> HostNotifications {
        let center = NotificationCenter()
        func named(_ name: String) -> HostNotification {
            HostNotification(center: center, name: Notification.Name("KernovaTests.\(name)"))
        }
        return HostNotifications(
            appDidBecomeActive: named("appDidBecomeActive"),
            systemWillSleep: named("systemWillSleep"),
            systemDidWake: named("systemDidWake"),
            volumeDidMount: named("volumeDidMount"),
            volumeDidUnmount: named("volumeDidUnmount"))
    }
}

extension VMLibrary {
    /// Whether any VM is held by a revert.
    var hasRevertInFlight: Bool {
        instances.contains {
            guard case .bringUp(.reverting)? = $0.phase.operation?.kind else { return false }
            return true
        }
    }

    /// Waits until no VM is held by a revert, including any a running revert's
    /// power-off admits.
    func waitForRevertsToSettle(fileID: String = #fileID, line: Int = #line) async throws {
        try await waitForChange(fileID: fileID, line: line) { [self] in !hasRevertInFlight }
    }

    /// Builds a fixture VM over this library's ``bundleFactory`` and adds it
    /// to the library as it stands, unwired and with its bundle's files in a
    /// store of its own — a test's stand-in for a VM a load would have
    /// adopted.
    ///
    /// The parameters are ``VMInstanceFixture/make(name:guestOS:phase:preferences:hostState:snapshots:pairings:files:bundleFactory:agentConnector:mutate:)``'s.
    @discardableResult
    func admitFixture(
        name: String = "Test VM",
        guestOS: VMGuestOS = .linux,
        phase: VMLifecyclePhase = .stopped,
        preferences: AppPreferences = makeTestPreferences(),
        hostState: VMHostState = VMHostState(),
        snapshots: VMSnapshotManifest = VMSnapshotManifest(),
        pairings: USBAccessoryPairingSet = USBAccessoryPairingSet(),
        files: InMemoryVMBundleFiles = InMemoryVMBundleFiles(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        admitForTesting(
            VMInstanceFixture.seed(
                name: name, guestOS: guestOS,
                hostState: VMInstanceFixture.hostState(hostState, placedAt: phase),
                snapshots: snapshots, pairings: pairings, files: files, mutate: mutate),
            phase: phase, preferences: preferences)
    }

    /// ``admitFixture(name:guestOS:phase:preferences:hostState:snapshots:pairings:files:mutate:)``,
    /// wired as a load would have left it and with its bundle's files in this
    /// library's storage: a `files` the test passes hands what it holds to
    /// that storage and writes through it from then on.
    @discardableResult
    func registerFixture(
        name: String = "Test VM",
        guestOS: VMGuestOS = .linux,
        phase: VMLifecyclePhase = .stopped,
        preferences: AppPreferences = makeTestPreferences(),
        hostState: VMHostState = VMHostState(),
        snapshots: VMSnapshotManifest = VMSnapshotManifest(),
        pairings: USBAccessoryPairingSet = USBAccessoryPairingSet(),
        files: InMemoryVMBundleFiles = InMemoryVMBundleFiles(),
        agentConnector: (any HostConnectionMaking)? = nil,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        guard let storage = storageService as? MockVMStorageService else {
            preconditionFailure("A fixture registers only with a library over MockVMStorageService")
        }
        let read = VMInstanceFixture.seed(
            name: name, guestOS: guestOS,
            hostState: VMInstanceFixture.hostState(hostState, placedAt: phase),
            snapshots: snapshots, pairings: pairings, files: files, mutate: mutate)
        files.forward(to: storage.files)
        let instance = admitForTesting(read, phase: phase, preferences: preferences, agentConnector: agentConnector)
        wireHooks(for: instance)
        return instance
    }

    /// A fixture VM over a real bundle directory
    /// (``VMInstanceFixture/seedOnDisk(name:guestOS:snapshots:mutate:)``),
    /// built over this library's ``bundleFactory`` and wired — for a test that
    /// drives the machine files the library was made over.
    @discardableResult
    func registerOnDiskFixture(
        name: String = "Test VM",
        guestOS: VMGuestOS = .linux,
        phase: VMLifecyclePhase = .stopped,
        preferences: AppPreferences = makeTestPreferences(),
        snapshots: VMSnapshotManifest = VMSnapshotManifest(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) throws -> VMInstance {
        let instance = admitForTesting(
            try VMInstanceFixture.seedOnDisk(
                name: name, guestOS: guestOS, snapshots: snapshots, mutate: mutate),
            phase: phase, preferences: preferences)
        wireHooks(for: instance)
        return instance
    }

    /// Applies `mutate` to `instance`'s host state as setup a test relies on,
    /// under a permit admission mints for `classes`, recording an issue when
    /// the edit is refused or does not land.
    func editHostState(
        of instance: VMInstance, as classes: VMEditClasses = .liveKeys,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ mutate: (inout VMHostState) -> Void
    ) {
        let write = try? instance.activity.edit(classes) { updateHostState($0, mutate: mutate) }
        guard case .saved? = write else {
            Issue.record("the host-state edit did not land", sourceLocation: sourceLocation)
            return
        }
    }

    /// Applies `mutate` to `instance`'s configuration as setup a test relies
    /// on, under a permit admission mints for `classes`, recording an issue
    /// when the edit is refused or does not land.
    func editConfiguration(
        of instance: VMInstance, as classes: VMEditClasses = .liveKeys,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ mutate: (inout VMConfiguration) -> Void
    ) {
        let write = try? instance.activity.edit(classes) { updateConfiguration($0, mutate: mutate) }
        guard case .saved? = write else {
            Issue.record("the configuration edit did not land", sourceLocation: sourceLocation)
            return
        }
    }

    /// ``updateConfiguration(_:mutate:)`` under a permit admission mints on
    /// `instance` for `classes`; throws the refusal when admission gives one.
    @discardableResult
    func updateConfiguration(
        of instance: VMInstance, as classes: VMEditClasses,
        mutate: (inout VMConfiguration) -> Void
    ) throws -> SettingsWrite {
        try instance.activity.edit(classes) { updateConfiguration($0, mutate: mutate) }
    }

    /// ``updateSettings(_:configuration:hostState:)`` under a permit admission
    /// mints on `instance` for `classes`.
    @discardableResult
    func updateSettings(
        of instance: VMInstance, as classes: VMEditClasses,
        configuration: (inout VMConfiguration) -> Void, hostState: (inout VMHostState) -> Void
    ) throws -> SettingsWrite {
        try instance.activity.edit(classes) {
            updateSettings($0, configuration: configuration, hostState: hostState)
        }
    }

    /// ``updateUSBPairings(_:mutate:)`` under a ``VMEditClasses/pairingRules``
    /// permit on `instance`.
    func updateUSBPairings(
        of instance: VMInstance, mutate: (inout USBAccessoryPairingSet) -> Void
    ) throws {
        try instance.activity.edit(.pairingRules) { try updateUSBPairings($0, mutate: mutate) }
    }
}

extension VMInstance {
    /// Puts `manifest` in this fixture VM's bundle as though the bundle already
    /// held it, snapshot MAC stubs included, and has the bundle read it back.
    ///
    /// For a VM built over ``InMemoryVMBundleFiles`` — what every fixture is.
    func seedSnapshotManifest(_ manifest: VMSnapshotManifest) {
        seedBundleFiles { $0.setManifest(manifest, at: bundleURL) }
        refreshBundle { try $0.bundle.commitSnapshotManifest { _ in } }
    }

    /// Rewrites this fixture VM's `config.json` as `edit` leaves the JSON
    /// object it holds — names and all, as a hand edit or another build could
    /// have written it — and has the bundle read it back.
    func seedConfigurationJSON(_ edit: (inout [String: Any]) -> Void) {
        let path = VMBundleLayout.configRelativePath
        seedBundleFiles { files in
            guard let data = files.data(atRelativePath: path, in: bundleURL),
                var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { preconditionFailure("'\(name)' holds no config.json object to edit") }
            edit(&object)
            files.setData(try? JSONSerialization.data(withJSONObject: object), atRelativePath: path, in: bundleURL)
        }
        refreshBundle { try $0.bundle.commitConfiguration { _ in } }
    }

    /// Puts a manifest recording `snapshots`, names and all, in this fixture
    /// VM's bundle — as a hand edit or another build could have written it —
    /// and has the bundle read it back.
    func seedSnapshotRecords(_ snapshots: [VMSnapshot]) {
        seedBundleFiles {
            $0.setManifestRecord(
                VMSnapshotManifestRecord(snapshots: snapshots.map(\.record), currentID: nil), at: bundleURL)
        }
        refreshBundle { try $0.bundle.commitSnapshotManifest { _ in } }
    }

    /// Puts `pairings` in this fixture VM's bundle as though the bundle
    /// already held them, and has the bundle read them back.
    func seedUSBPairings(_ pairings: USBAccessoryPairingSet) {
        seedBundleFiles { $0.setPairings(pairings, at: bundleURL) }
        refreshBundle { try $0.bundle.commitUSBPairings { _ in } }
    }

    /// The in-memory store this fixture VM's bundle files live in — the store
    /// a library it was registered with owns, once registered.
    var fixtureBundleFiles: InMemoryVMBundleFiles {
        guard let files = bundle.fileAccessForTesting as? InMemoryVMBundleFiles else {
            preconditionFailure("'\(name)' is not a fixture VM over in-memory bundle files")
        }
        return files
    }

    /// The snapshot manifest this fixture VM's bundle holds on "disk".
    var manifestOnDisk: VMSnapshotManifest? { fixtureBundleFiles.manifest(at: bundleURL) }

    private func seedBundleFiles(_ seed: (InMemoryVMBundleFiles) -> Void) {
        seed(fixtureBundleFiles)
    }

    /// A commit that changes nothing reads the file and publishes what it
    /// holds, which is how a seeded file reaches memory — made under a
    /// ``VMEditClasses/observations`` permit, which every phase a fixture
    /// seeds in admits.
    private func refreshBundle(_ commit: (borrowing VMEditPermit) throws -> Void) {
        do {
            try activity.edit(.observations, commit)
        } catch {
            preconditionFailure("A seeded bundle file could not be read back: \(error)")
        }
    }
}

extension VMHostState {
    /// Ephemeral Mode on, reverting to `baseline`.
    static func ephemeral(baseline: UUID) -> VMHostState {
        var hostState = VMHostState()
        hostState.applyEphemeralMode(enabled: true, baseline: baseline)
        return hostState
    }
}

/// A `VMIndexRecord` over an in-memory store, holding `indexed` as an earlier
/// run's record of what it wrote to Spotlight.
@MainActor
func makeTestIndexRecord(_ indexed: Set<UUID> = []) -> VMIndexRecord {
    let record = VMIndexRecord(defaults: makeTestDefaults())
    record.indexedVMIDs = indexed
    return record
}

// MARK: - VZ error fixtures

/// `VirtualizationFailure.Framework.Code.installationFailed`, which no classifier reads.
let vzInstallationFailedCode = 10007

/// The plain-start shape of the running-VM cap: VZ reports the code at the top
/// level.
func makeVMLimitExceededError() -> NSError {
    NSError(
        domain: VirtualizationFailure.Framework.errorDomain,
        code: VirtualizationFailure.Framework.Code.virtualMachineLimitExceeded.rawValue)
}

/// The install shape of the same cap: `VZMacOSInstaller.install()` reports it as
/// `.installationFailed` with the real code underneath, so only a chain walk
/// classifies it.
func makeInstallVMLimitExceededError() -> NSError {
    makeVZErrorChain(depth: 1, around: makeVMLimitExceededError())
}

/// `error` wrapped in `depth` nested `.installationFailed` errors.
func makeVZErrorChain(depth: Int, around error: NSError) -> NSError {
    var wrapped = error
    for _ in 0..<depth {
        wrapped = NSError(
            domain: VirtualizationFailure.Framework.errorDomain,
            code: vzInstallationFailedCode,
            userInfo: [NSUnderlyingErrorKey: wrapped])
    }
    return wrapped
}

// MARK: - Operation phases

extension VMLifecyclePhase {
    /// An operation of `kind` holding a VM admitted from `startedFrom` — the
    /// phase ``VMActivity`` commits, for a test to place.
    ///
    /// The operation holds the settled live session `startedFrom` names, or the
    /// running session `boundSession` names once a bring-up bound one; none once
    /// `sessionEnd` says the session ended. A ``VMOperationKind/forceStopping``
    /// session is stopping under the operation's own outcome, as every one
    /// ``VMActivity`` commits is.
    @MainActor
    static func operating(
        _ kind: VMOperationKind, from startedFrom: VMLifecyclePhase,
        boundSession: UUID? = nil, sessionEnd: VMSessionEnd? = nil
    ) -> VMLifecyclePhase {
        let outcome = VMOutcome()
        let stopping = kind == .forceStopping ? outcome : nil
        let sessionState: VMOperationSessionState
        if let sessionEnd {
            sessionState = .ended(sessionEnd)
        } else if let boundSession {
            sessionState = .live(VMOperationSession(id: boundSession, guest: .running))
        } else {
            switch startedFrom {
            case .running(let id):
                sessionState = .live(VMOperationSession(id: id, guest: .running, stopping: stopping))
            case .livePaused(let id):
                sessionState = .live(VMOperationSession(id: id, guest: .paused, stopping: stopping))
            default:
                sessionState = .none
            }
        }
        return .operating(
            VMOperation(
                kind: kind, startedFrom: startedFrom, sessionState: sessionState, outcome: outcome))
    }
}

/// A phase a parameterized test places, described without the ``VMOutcome``
/// an operation carries — so an argument list, which is built off the main
/// actor, can name an operation.
enum PhaseFixture: Sendable, CustomTestStringConvertible {
    case settled(VMLifecyclePhase)
    case operating(VMOperationKind, from: VMLifecyclePhase, boundSession: UUID? = nil)

    @MainActor
    var phase: VMLifecyclePhase {
        switch self {
        case .settled(let phase):
            phase
        case .operating(let kind, let startedFrom, let boundSession):
            .operating(kind, from: startedFrom, boundSession: boundSession)
        }
    }

    var testDescription: String {
        switch self {
        case .settled(let phase): "\(phase)"
        case .operating(let kind, let startedFrom, _): "\(kind) from \(startedFrom)"
        }
    }
}

extension VMCapabilityCatalog.GuestAccountState {
    /// Whether the account question is outstanding.
    var isOwed: Bool {
        if case .owed = self { return true }
        return false
    }
}

extension VMActivity {
    /// Launches the bring-up `kind` names through the entry it takes — a
    /// guest start through ``launchStartGuest(_:resolving:_:)``, any other
    /// through ``launchBringUp(_:whenEnded:_:)`` — running `body` under its
    /// bring-up context; for a test that reaches every bring-up alike.
    @discardableResult
    func launchAnyBringUp(
        _ kind: VMBringUpKind,
        _ body: @escaping @MainActor (borrowing VMBringUpContext) async throws -> VMOperationEnding<Void>
    ) throws -> VMOutcome {
        guard let nonStart = VMNonStartBringUpKind(kind) else {
            guard case .guestStart(let start) = kind else { preconditionFailure("\(kind)") }
            return try launchStartGuest(start) { try await body($0.bringUp) }
        }
        return try launchBringUp(nonStart, body)
    }

    /// Whether `request` is admitted outright right now.
    func admits(_ request: VMAdmission.Request, posture: VMAdmission.Posture = .commit) -> Bool {
        decide(request, posture: posture) == .admit
    }
}

extension VMNonBringUpKind {
    /// `kind`, unless it is a bring-up.
    init?(_ kind: VMOperationKind) {
        switch kind {
        case .bringUp: return nil
        case .pausing: self = .pausing
        case .resuming: self = .resuming
        case .saving: self = .saving
        case .capturingSnapshot(let mode): self = .capturingSnapshot(mode)
        case .deletingSnapshot: self = .deletingSnapshot
        case .attachingUSB(let registryID): self = .attachingUSB(registryID: registryID)
        case .detachingUSB(let deviceID): self = .detachingUSB(deviceID: deviceID)
        case .reconcilingMedia: self = .reconcilingMedia
        case .forceStopping: self = .forceStopping
        case .discardingSavedState: self = .discardingSavedState
        case .deleting: self = .deleting
        case .creatingStorageDisk: self = .creatingStorageDisk
        case .removingStorageDisk: self = .removingStorageDisk
        case .creatingRemovableMedia: self = .creatingRemovableMedia
        case .copyingOut(let mode): self = .copyingOut(mode)
        }
    }
}

extension VMNonStartBringUpKind {
    /// `kind`, unless it is a guest start.
    init?(_ kind: VMBringUpKind) {
        switch kind {
        case .guestStart: return nil
        case .settingUp(let setup): self = .settingUp(setup)
        case .reverting(let snapshotID, let resumesAfter):
            self = .reverting(snapshotID: snapshotID, resumesAfter: resumesAfter)
        }
    }
}

/// Runs `body` inside an operation holding a stopped VM built around `bundle`,
/// answering what it returns — how a test reaches `bundle`'s machine-file
/// operations, as ``VMOperationContext/bundle``.
@MainActor
func withOperation<T>(
    on bundle: VMBundle, _ body: (borrowing VMOperationContext) async throws -> T
) async throws -> T {
    let instance = VMInstance(
        bundle: bundle, phase: .stopped, preferences: makeTestPreferences(), hostPasteboard: FakePasteboard(),
        bundleProducts: .testing)
    return try await withOperation(on: instance, .deletingSnapshot, body)
}

/// Runs `body` as the operation `kind` on `instance`, which rests where it
/// started — what a test needs to act with an operation's context, or with
/// the permit its own writes hold.
@MainActor
func withOperation<T>(
    on instance: VMInstance, _ kind: VMNonBringUpKind = .deletingSnapshot,
    _ body: (borrowing VMOperationContext) async throws -> T
) async throws -> T {
    try await instance.activity.perform(kind) { context in
        .rest(.asStarted, try await body(context))
    }
}

/// The synchronous ``withOperation(on:_:_:)``.
@MainActor
func withOperationNow<T>(
    on instance: VMInstance, _ kind: VMNonBringUpKind = .deletingSnapshot,
    _ body: (borrowing VMOperationContext) throws -> T
) throws -> T {
    try instance.activity.performNow(kind) { context in
        .rest(.asStarted, try body(context))
    }
}

extension VMInstance {
    /// Whether a revert holds the VM.
    var isHeldByRevert: Bool {
        guard case .bringUp(.reverting)? = phase.operation?.kind else { return false }
        return true
    }

    /// The task the guest setup holding the VM runs in, or `nil` when none
    /// holds it — what a test cancels and waits out so nothing outlives it.
    var setupOperationTask: Task<Void, Never>? {
        guard let operation = phase.operation, operation.kind.belongs(to: .guestSetup) else {
            return nil
        }
        return operation.outcome.task
    }
}

extension VMLibraryViewModel {
    /// Awaits every arrival in the library, including any registered while an
    /// earlier one is awaited, returning once each has left its row and
    /// reported a failure nobody awaited (``VMArrival/isAwaited``) — both land
    /// in the step its outcome settles in.
    func awaitArrivals(fileID: String = #fileID, line: Int = #line) async throws {
        while let arrival = library.arrivals.first {
            _ = try await arrival.settled.joinedResult(fileID: fileID, line: line)
        }
    }
}

// MARK: - VM idle

extension VMInstance {
    /// Whether this VM holds no operation and has none queued.
    var isIdle: Bool { phase.isSettled && activity.queuedFollowUpCountForTesting == 0 }

    /// Waits until ``isIdle``, so every follow-up this VM was handed has run.
    ///
    /// The queue is not observed, but it drains only as the observed `phase`
    /// settles, so each check is woken by a `phase` change.
    func waitUntilIdle() async throws {
        try await waitForChange { [self] in isIdle }
    }
}

// MARK: - waitForChange

/// Production's ``waitForObservedChange(until:before:)`` as a test wait: it
/// returns in a turn where the predicate holds, and throws `TestFailure` when
/// `timeout` passes first, or when the predicate holds only once the deadline
/// re-reads it — no observed change made it hold, so what it reads is not
/// observed.
///
/// The predicate carries the production wait's contract.
@MainActor
func waitForChange(
    timeout: TimeInterval = testWaitBackstop, fileID: String = #fileID, line: Int = #line,
    until predicate: @escaping @MainActor () -> Bool
) async throws {
    let backstop = Backstop("waitForChange", timeout: timeout, fileID: fileID, line: line)
    // The production wait answers from the observation loop's apply, a hop
    // before this caller resumes, and work queued between the two can move the
    // state again — so the answer is re-read here, in the caller's own turn.
    while !predicate() {
        let remaining = backstop.remaining
        guard remaining > 0,
            await waitForObservedChange(
                until: predicate,
                before: ObservedChangeDeadline(seconds: remaining, clock: MonotonicEngineClock()))
        else {
            throw backstop.failure()
        }
        guard !backstop.expired else {
            throw backstop.failure(
                "its predicate held only when the deadline re-read it: no observed change to what it reads made it hold"
            )
        }
    }
}

/// Records that a `withObservationTracking` `onChange` fired, from the
/// `@Sendable` closure the API hands it — which no actor-isolated state can be
/// written from.
final class ObservationFireRecorder: Sendable {
    private let fired = Mutex(false)

    var didFire: Bool { fired.withLock { $0 } }

    func record() { fired.withLock { $0 = true } }
}

extension VMMemorySize {
    /// This size grown by `gibibytes`.
    func adding(gibibytes: UInt32) -> VMMemorySize {
        VMMemorySize(mebibytes: mebibytes + VMMemorySize.gibibytes(gibibytes).mebibytes)
    }
}

extension VMOutcome {
    /// ``value()`` under the backstop: waits for the operation to end and
    /// rethrows how it failed, throwing `Backstop.failure(_:)` when it is
    /// still running at the deadline.
    func resolved(fileID: String = #fileID, line: Int = #line) async throws {
        try await Backstop("VMOutcome.value()", fileID: fileID, line: line).run { try await self.value() }
    }

    /// How the operation ended, once it has, waited for as
    /// ``resolved(fileID:line:)`` waits.
    func resolution(fileID: String = #fileID, line: Int = #line) async throws -> Result<Void, any Error> {
        try await Backstop("VMOutcome.ended()", fileID: fileID, line: line).run { await self.ended() }
    }
}

extension VMActivity {
    /// A snapshot capture in `mode` launched as production launches one
    /// (``launchCaptureSnapshot(_:resolving:_:)``) and awaited, answering
    /// what `body` captured.
    @MainActor
    func launchedCapture<T: Sendable>(
        _ mode: VMCaptureMode,
        _ body: @escaping @MainActor (borrowing VMCaptureContext) async throws -> VMOperationEnding<T>
    ) async throws -> T {
        let outcome = VMOutcome()
        let landed = Landed<T>()
        try launchCaptureSnapshot(mode, resolving: outcome) { context in
            switch try await body(context) {
            case .rest(let rest, let value):
                landed.value = value
                return .rest(rest, ())
            case .failed(let rest, let error):
                return .failed(rest, error)
            }
        }
        try await outcome.resolved()
        return try #require(landed.value)
    }
}

/// What a launched operation's body answered, set inside the operation.
@MainActor
private final class Landed<T> {
    var value: T?
}
