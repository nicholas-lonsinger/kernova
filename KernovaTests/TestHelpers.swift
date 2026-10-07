import AppKit
import Darwin
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing
import Virtualization

@testable import Kernova

// Bundle-specific test helpers for KernovaTests. The event-driven/poll wait
// primitives (`AsyncGate`, `waitUntil`, `TestFailure`), the in-memory
// `UserDefaults` double (`MemoryUserDefaults`, `makeTestDefaults`), and the
// blocking-bridge GCD hop (`offCooperativePool`) live in the shared
// `KernovaTestSupport` package product — see its doc comments.
//
// `waitForChange` below is KernovaTests-only: it is built on the app's
// `waitForObservedChange`, and only this bundle's tests wait on `@Observable`
// production state — the GuestAgent/KernovaKit bundles' predicates read
// `Sendable` boxes (`AtomicInt`, `PolicyBox`) with no such observable type to
// track.

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
/// No Downloads directory unless a test names one: a test that needs it passes
/// a temporary directory, never the user's own.
@MainActor
func makeTestLifecycle(
    virtualization: any VirtualizationProviding = MockVirtualizationService(),
    installService: any MacOSInstallProviding = MockMacOSInstallService(),
    ipswService: any IPSWProviding = MockIPSWService(),
    removableMedia: any RemovableMediaAttaching = MockRemovableMediaDeviceService(),
    liveDirectorySharing: any LiveDirectorySharing = MockLiveDirectorySharing(),
    usbAccessoryService: (any USBAccessoryProviding)? = nil,
    linuxImageResolveService: any LinuxImageResolving = MockLinuxImageResolveService(),
    downloadService: any Downloading = MockDownloadService(),
    fileSystem: MockFileSystem = MockFileSystem(),
    downloadsDirectory: URL? = nil
) -> VMLifecycleCoordinator {
    VMLifecycleCoordinator(
        virtualizationService: virtualization,
        installService: installService,
        ipswService: ipswService,
        removableMediaDeviceService: removableMedia,
        liveDirectorySharing: liveDirectorySharing,
        usbAccessoryService: usbAccessoryService,
        linuxImageResolveService: linuxImageResolveService,
        downloadService: downloadService,
        fileSystem: fileSystem,
        downloadsDirectory: downloadsDirectory)
}

/// A real `VMLibrary` over mocks: the test target's one construction of a
/// library, and what a test changes a VM's configuration through once the VM
/// exists, since only the library writes it. Its VMs come from
/// ``VMLibrary/registerFixture(name:guestOS:phase:preferences:hostState:snapshots:pairings:files:mutate:)``.
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
    vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider(),
    arpTable: ScriptedARPTable = ScriptedARPTable(),
    entitlements: EntitlementService = .entitled,
    networks: VMNetworkDirectory = VMNetworkDirectory(fileURL: nil),
    guestAccountPasswords: any GuestAccountPasswordStoring = InMemoryGuestAccountPasswordStore(),
    bridgedInterfaces: any BridgedInterfaceProviding = MockBridgedInterfaceProvider(),
    activationCenter: NotificationCenter = NotificationCenter()
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
        guestAccountPasswords: guestAccountPasswords,
        bridgedInterfaces: bridgedInterfaces,
        activationCenter: activationCenter)
    return library
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
    func waitForRevertsToSettle() async {
        await waitForObservedChange { [self] in !hasRevertInFlight }
    }

    /// Builds a fixture VM over this library's ``bundleFactory`` and adds it
    /// to the library as it stands, unwired and with its bundle's files in a
    /// store of its own — a test's stand-in for a VM a load would have
    /// adopted.
    ///
    /// The parameters are ``VMInstanceFixture/make(name:guestOS:phase:preferences:hostState:snapshots:pairings:files:bundleFactory:mutate:)``'s.
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
                name: name, guestOS: guestOS, hostState: hostState, snapshots: snapshots,
                pairings: pairings, files: files, mutate: mutate),
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
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        guard let storage = storageService as? MockVMStorageService else {
            preconditionFailure("A fixture registers only with a library over MockVMStorageService")
        }
        let read = VMInstanceFixture.seed(
            name: name, guestOS: guestOS, hostState: hostState, snapshots: snapshots,
            pairings: pairings, files: files, mutate: mutate)
        files.forward(to: storage.files)
        let instance = admitForTesting(read, phase: phase, preferences: preferences)
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
    /// Commits `change` to this VM's snapshot manifest as setup a test relies
    /// on, as the write of an operation holding the VM — what lists a
    /// snapshot or moves the current marker.
    func editSnapshotManifest(_ change: (inout VMSnapshotManifest) -> Void) throws {
        try withOperationNow(on: self) { try $0.permit.bundle.commitSnapshotManifest(change) }
    }

    /// Puts `manifest` in this fixture VM's bundle as though the bundle already
    /// held it, snapshot MAC stubs included, and has the bundle read it back.
    ///
    /// For a VM built over ``InMemoryVMBundleFiles`` — what every fixture is.
    func seedSnapshotManifest(_ manifest: VMSnapshotManifest) {
        seedBundleFiles { $0.setManifest(manifest, at: bundleURL) }
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

/// The plain-start shape of the running-VM cap: VZ reports the code at the top
/// level.
func makeVMLimitExceededError() -> NSError {
    NSError(
        domain: VZError.errorDomain,
        code: VZError.Code.virtualMachineLimitExceeded.rawValue)
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
            domain: VZError.errorDomain,
            code: VZError.Code.installationFailed.rawValue,
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

/// Runs `body` inside an operation holding a stopped VM built around `bundle`,
/// answering what it returns — how a test reaches `bundle`'s machine-file
/// operations, as ``VMOperationContext/bundle``.
@MainActor
func withOperation<T>(
    on bundle: VMBundle, _ body: (borrowing VMOperationContext) async throws -> T
) async throws -> T {
    let instance = VMInstance(bundle: bundle, phase: .stopped, preferences: makeTestPreferences())
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

    /// Launches a guest setup operation whose body parks until cancelled —
    /// an install or download in flight, as far as anything reading the VM can
    /// tell — calling `onCancel` as the cancel lands.
    ///
    /// The VM must owe the setup and be at rest, as any launch requires.
    @discardableResult
    func launchParkedSetup(onCancel: @escaping @Sendable () -> Void = {}) throws -> VMOutcome {
        let kind: GuestSetupKind =
            configuration.linuxInstallContext != nil ? .linuxImageDownload : .macOSInstall
        return try activity.launchBringUp(.settingUp(kind)) {
            (_: borrowing VMBringUpContext) async throws -> VMOperationEnding<Void> in
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(60))
            } onCancel: {
                onCancel()
            }
            throw CancellationError()
        }
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

// MARK: - Live-session vsock fixtures

/// An instance standing in for one with a live session: every feature toggle on
/// and the handshake published, so each channel's listener admits a connection
/// and its accept path installs a service.
///
/// The phase's session identity stands in for a live `VZVirtualMachine`, not for
/// the session context the services and their hand-offs live in — hence the
/// explicit `beginSessionContextForTesting()`.
@MainActor
func makeInstanceWithLiveSession(named name: String = "Live Session VM")
    -> (instance: VMInstance, sessionID: UUID)
{
    enterLiveSession(
        VMInstanceFixture.make(name: name, guestOS: .macOS, mutate: enableEveryLiveSessionFeature))
}

extension VMLibrary {
    /// ``makeInstanceWithLiveSession(named:)``, registered with this library.
    func registerInstanceWithLiveSession(named name: String = "Live Session VM")
        -> (instance: VMInstance, sessionID: UUID)
    {
        enterLiveSession(
            registerFixture(name: name, guestOS: .macOS, mutate: enableEveryLiveSessionFeature))
    }
}

private func enableEveryLiveSessionFeature(_ config: inout VMConfiguration) {
    config.clipboardSharingEnabled = true
    config.agentLogForwardingEnabled = true
    config.dropFilesEnabled = true
}

@MainActor
private func enterLiveSession(_ instance: VMInstance) -> (instance: VMInstance, sessionID: UUID) {
    let sessionID = UUID()
    instance.activity.placeForTesting(.running(sessionID: sessionID))
    instance.beginSessionContextForTesting()
    instance.vsockAdmissionGate.publish(
        VsockAdmissionGate.State(
            handshakeComplete: true,
            capabilities: Set(KernovaCapability.controlChannelDefaults)))
    return (instance, sessionID)
}

/// Asserts `sink` forwards nothing — a descriptor handed to it is closed, which
/// the peer of a socket pair sees as EOF.
@MainActor
func expectSinkCleared(_ sink: VsockDataConnectionSink) throws {
    let (a, b) = try makeRawSocketPair()
    defer { close(b) }  // `a` is owned — and must be closed — by the sink.
    sink.accept(fd: a)
    #expect(fcntl(b, F_SETFL, O_NONBLOCK) >= 0)
    var byte: UInt8 = 0
    #expect(recv(b, &byte, 1, 0) == 0)
}

// MARK: - expectEOF

/// Asserts `channel` reaches EOF — the peer closed its end — rather than
/// producing another frame.
///
/// Event-driven via `nextFrame`, whose stuck-stream backstop bounds the wait:
/// EOF resolves it immediately, a frame or a timeout records a test failure.
/// Used by the #145 channel-admission tests to observe a service dropping a
/// non-conformant peer.
@MainActor
func expectEOF(on channel: VsockChannel) async {
    do {
        let frame = try await nextFrame(from: channel)
        Issue.record("Expected channel EOF, got frame \(String(describing: frame.payload))")
    } catch let failure as TestFailure {
        #expect(failure.message.contains("EOF"), "Expected EOF, got: \(failure.message)")
    } catch {
        Issue.record("Expected channel EOF, got error \(error)")
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
/// The predicate carries the production wait's contract. One over plain
/// non-observed state keeps `waitUntil`.
@MainActor
func waitForChange(
    timeout: TimeInterval = testWaitBackstop,
    until predicate: @escaping @MainActor () -> Bool
) async throws {
    let stopwatch = BackstopStopwatch()
    // The production wait answers from the observation loop's apply, a hop
    // before this caller resumes, and work queued between the two can move the
    // state again — so the answer is re-read here, in the caller's own turn.
    while !predicate() {
        let remaining = timeout - stopwatch.elapsed
        guard remaining > 0,
            await waitForObservedChange(
                until: predicate,
                before: ObservedChangeDeadline(seconds: remaining, clock: MonotonicEngineClock()))
        else {
            throw TestFailure.backstop(
                "Observed condition not met within \(timeout) s", stopwatch: stopwatch, timeout: timeout)
        }
        guard stopwatch.elapsed < timeout else {
            throw TestFailure.backstop(
                "Condition held only when the deadline re-read it: no observed change to what the predicate reads made it hold",
                stopwatch: stopwatch, timeout: timeout)
        }
    }
}

/// Records that a `withObservationTracking` `onChange` fired, from the
/// `@Sendable` closure the API hands it — which no actor-isolated state can be
/// written from.
final class ObservationFireRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var didFire: Bool { lock.withLock { value } }

    func record() { lock.withLock { value = true } }
}

// MARK: - View-tree search

/// The first `T` that `matches` in the subtree rooted at `view`, depth-first.
@MainActor
func firstSubview<T: NSView>(
    _ type: T.Type, in view: NSView, where matches: (T) -> Bool = { _ in true }
) -> T? {
    if let candidate = view as? T, matches(candidate) { return candidate }
    for subview in view.subviews {
        if let match = firstSubview(type, in: subview, where: matches) { return match }
    }
    return nil
}

/// Every `T` that `matches` in the subtree rooted at `view`, depth-first.
@MainActor
func allSubviews<T: NSView>(
    _ type: T.Type, in view: NSView, where matches: (T) -> Bool = { _ in true }
) -> [T] {
    var found: [T] = []
    if let candidate = view as? T, matches(candidate) { found.append(candidate) }
    for subview in view.subviews {
        found.append(contentsOf: allSubviews(type, in: subview, where: matches))
    }
    return found
}

/// The first push button titled `title` in the subtree rooted at `view`.
///
/// Skips pop-up buttons, whose `title` is whichever item is selected.
@MainActor
func findButton(titled title: String, in view: NSView) -> NSButton? {
    firstSubview(NSButton.self, in: view) { !($0 is NSPopUpButton) && $0.title == title }
}

/// The first label reading exactly `text` in the subtree rooted at `view`.
@MainActor
func findLabel(withText text: String, in view: NSView) -> NSTextField? {
    firstSubview(NSTextField.self, in: view) { $0.stringValue == text }
}

/// The first label whose text contains `text` in the subtree rooted at `view`.
@MainActor
func findLabel(containing text: String, in view: NSView) -> NSTextField? {
    firstSubview(NSTextField.self, in: view) { $0.stringValue.contains(text) }
}

/// The first editable text field in the subtree rooted at `view`.
@MainActor
func findEditableField(in view: NSView) -> NSTextField? {
    firstSubview(NSTextField.self, in: view) { $0.isEditable }
}

/// Every text field in the subtree rooted at `view`, in depth-first order.
@MainActor
func collectLabels(in view: NSView) -> [NSTextField] {
    allSubviews(NSTextField.self, in: view)
}

/// Whether `view` and every ancestor up to `root` is unhidden — what it takes
/// for `view` to actually be on screen within `root`.
@MainActor
func isVisible(_ view: NSView, within root: NSView) -> Bool {
    var node: NSView? = view
    while let current = node {
        if current.isHidden { return false }
        if current === root { return true }
        node = current.superview
    }
    return true
}

// MARK: - ChannelLostRecorder

/// Counts a vsock feature service's `onChannelLost` invocations, optionally
/// sampling service state at callback time.
///
/// `sample` is assigned after the service exists, since the thing worth sampling
/// is the service the recorder is wired into. Main-bound because `onChannelLost`
/// is `@MainActor` in production, not by convenience.
@MainActor
final class ChannelLostRecorder {
    private(set) var count = 0

    /// What `sample` returned at each invocation, in order — the state the owner
    /// observes from inside the callback.
    private(set) var samples: [String?] = []

    /// Read once per `record`; leave it nil for a test asserting only on `count`.
    var sample: (@MainActor () -> String?)?

    /// Fires on every `record`; await it instead of polling `count`.
    let changed = AsyncGate()

    func record() {
        count += 1
        samples.append(sample.flatMap { $0() })
        changed.notify()
    }
}

extension VMMemorySize {
    /// This size grown by `gibibytes`.
    func adding(gibibytes: UInt32) -> VMMemorySize {
        VMMemorySize(mebibytes: mebibytes + VMMemorySize.gibibytes(gibibytes).mebibytes)
    }
}

extension NSColor {
    /// This color resolved to sRGB as drawn under the named appearance.
    func resolvedSRGB(in appearance: NSAppearance.Name) throws -> NSColor {
        var resolved: NSColor?
        try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            resolved = usingColorSpace(.sRGB)
        }
        return try #require(resolved)
    }
}

extension NSView {
    /// The accessibility elements VoiceOver reaches inside this view, in order.
    @MainActor
    var unignoredAccessibilityElements: [NSAccessibilityProtocol] {
        NSAccessibility.unignoredChildren(from: accessibilityChildren() ?? [])
            .compactMap { $0 as? NSAccessibilityProtocol }
    }
}
