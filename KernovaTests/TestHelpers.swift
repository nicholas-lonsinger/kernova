import AppKit
import Darwin
import Foundation
import Observation
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
// `waitForChange` below is KernovaTests-only: it observes `@MainActor`
// `@Observable` production state
// directly via `withObservationTracking`, which only this bundle's tests need
// — the GuestAgent/KernovaKit bundles' predicates read `Sendable` boxes
// (`AtomicInt`, `PolicyBox`) with no such observable type to track.

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
    usbAccessoryService: (any USBAccessoryProviding)? = nil,
    usbAccessoryReturnTimeout: Duration = .seconds(5),
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
        usbAccessoryService: usbAccessoryService,
        usbAccessoryReturnTimeout: usbAccessoryReturnTimeout,
        linuxImageResolveService: linuxImageResolveService,
        downloadService: downloadService,
        fileSystem: fileSystem,
        downloadsDirectory: downloadsDirectory)
}

/// A real `VMLibrary` over mocks, holding `instances` registered as a load
/// would have left them: the test target's one construction of a library, and
/// what a test changes a VM's configuration through once the VM exists, since
/// only the library writes it.
///
/// The caller keeps the library alive for as long as it edits: each instance
/// reaches it weakly.
@MainActor
func makeWiredLibrary(
    holding instances: [VMInstance] = [],
    storage: MockVMStorageService = MockVMStorageService(),
    snapshotStore: (any VMSnapshotStoring)? = nil,
    lifecycle: VMLifecycleCoordinator? = nil,
    fileSystem: MockFileSystem = MockFileSystem(),
    preferences: AppPreferences = makeTestPreferences(),
    vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider(),
    arpTable: ScriptedARPTable = ScriptedARPTable(),
    guestAccountPasswords: any GuestAccountPasswordStoring = InMemoryGuestAccountPasswordStore()
) -> VMLibrary {
    let library = VMLibrary(
        storageService: storage,
        snapshotStore: snapshotStore ?? MockVMSnapshotStore(files: storage.files),
        lifecycle: lifecycle ?? makeTestLifecycle(fileSystem: fileSystem),
        preferences: preferences,
        vmnetNetworks: vmnetNetworks,
        arpTable: arpTable,
        entitlements: .entitled,
        guestAccountPasswords: guestAccountPasswords)
    for instance in instances {
        library.register(instance, storage: storage)
    }
    return library
}

extension VMLibrary {
    /// Adds each of `instances`, in order, unwired and unread.
    func admitForTesting(_ instances: [VMInstance]) {
        for instance in instances {
            admitForTesting(instance)
        }
    }

    /// Wires `instance` and adds it to the library, with its bundle's files in
    /// `storage` as a load would have found them: a fixture built over a store
    /// of its own hands that store's files to `storage` and writes through it
    /// from then on.
    func register(_ instance: VMInstance, storage: MockVMStorageService) {
        if let files = instance.bundle.fileAccessForTesting as? InMemoryVMBundleFiles {
            files.forward(to: storage.files)
        }
        wireHooks(for: instance)
        admitForTesting(instance)
    }

    /// Applies `mutate` to `instance`'s host state as setup a test relies on,
    /// recording an issue when the write does not land.
    func editHostState(
        of instance: VMInstance,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ mutate: (inout VMHostState) -> Void
    ) {
        guard
            case .saved = updateHostState(of: instance, mutate: mutate)
        else {
            Issue.record("the host-state edit did not land", sourceLocation: sourceLocation)
            return
        }
    }

    /// Applies `mutate` to `instance`'s configuration as setup a test relies
    /// on, recording an issue when the write is refused or does not land.
    func editConfiguration(
        of instance: VMInstance,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ mutate: (inout VMConfiguration) -> Void
    ) {
        guard case .saved = updateConfiguration(of: instance, mutate: mutate)
        else {
            Issue.record("the configuration edit did not land", sourceLocation: sourceLocation)
            return
        }
    }
}

extension VMInstance {
    /// Puts `manifest` in this fixture VM's bundle as though the bundle already
    /// held it, snapshot MAC stubs included, and has the bundle read it back.
    ///
    /// For a VM built over ``InMemoryVMBundleFiles`` — what every fixture is.
    func seedSnapshotManifest(_ manifest: VMSnapshotManifest) {
        seedBundleFiles { $0.setManifest(manifest, at: bundleURL) }
        refreshBundle { try $0.commitSnapshotManifest { _ in } }
    }

    /// Puts `pairings` in this fixture VM's bundle as though the bundle
    /// already held them, and has the bundle read them back.
    func seedUSBPairings(_ pairings: USBAccessoryPairingSet) {
        seedBundleFiles { $0.setPairings(pairings, at: bundleURL) }
        refreshBundle { try $0.commitUSBPairings { _ in } }
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
    /// holds, which is how a seeded file reaches memory.
    private func refreshBundle(_ commit: (VMBundle) throws -> Void) {
        do {
            try commit(bundle)
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

// MARK: - Live-session vsock fixtures

/// An instance standing in for one with a live session: every feature toggle on
/// and the handshake published, so each channel's listener admits a connection
/// and its accept path installs a service.
///
/// The phase's session identity stands in for a live `VZVirtualMachine`, not for
/// the session context the services and their hand-offs live in — hence the
/// explicit `beginSessionContext()`.
@MainActor
func makeInstanceWithLiveSession(named name: String = "Live Session VM")
    -> (instance: VMInstance, sessionID: UUID)
{
    let instance = VMInstanceFixture.make(name: name, guestOS: .macOS) {
        $0.clipboardSharingEnabled = true
        $0.agentLogForwardingEnabled = true
        $0.dropFilesEnabled = true
    }
    let sessionID = UUID()
    instance.enter(.running(sessionID: sessionID))
    instance.beginSessionContext()
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

// MARK: - waitForChange

/// Event-driven replacement for `waitUntil` when the predicate reads
/// `@Observable` state on a production object directly — i.e. there is no test
/// double in the loop to call `AsyncGate.notify()`.
///
/// `withObservationTracking` suspends the waiter until a property the predicate
/// actually reads changes, then the loop re-checks — so the wait resolves on the
/// mutation itself, not on a 50 ms poll tick. Like `AsyncGate`, an idle waiter
/// adds **zero** wake-ups to the shared (and, on CI, contended) MainActor, and
/// `timeout` is a stuck-condition backstop the happy path never reaches rather
/// than the success deadline. This is the fix for the poll-budget flakes in the
/// flaky-CI investigation.
///
/// The predicate must read every value it inspects through an `@Observable`
/// getter so tracking registers a dependency, and it must be **side-effect-free**
/// — it is evaluated several times per wait (the arming pass, the immediate-hit
/// re-check, and each outer-loop iteration). Computed properties that read
/// observed stored properties qualify (e.g. `agentStatus` reads `isUnresponsive`),
/// but tracking only registers the properties actually read on the arming pass:
/// a getter that short-circuits *before* reaching the property that will change
/// won't wake the waiter, which then resolves only via the deadline backstop. A
/// predicate over plain non-observed state would never be re-evaluated and must
/// keep `waitUntil`.
@MainActor
func waitForChange(
    timeout: Duration = .seconds(testWaitBackstop),
    until predicate: @escaping @MainActor () -> Bool
) async throws {
    let stopwatch = BackstopStopwatch()
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !predicate() {
        if ContinuousClock.now >= deadline {
            throw TestFailure.backstop(
                "Observed condition not met within \(timeout)",
                stopwatch: stopwatch, timeout: timeout)
        }
        await armObservationOnce(deadline: deadline, predicate: predicate)
    }
}

/// Suspends until the next change to any `@Observable` property read by
/// `predicate`, an immediate hit (the predicate already holds at arm time,
/// closing the arm-vs-change race), or the `deadline` backstop — whichever
/// comes first.
///
/// Mirrors `AsyncGate.armOnce`, but the wake source is observation tracking
/// instead of an explicit `notify()`.
@MainActor
private func armObservationOnce(
    deadline: ContinuousClock.Instant,
    predicate: @escaping @MainActor () -> Bool
) async {
    // Captured so it can be cancelled once the wait resolves via observation (or
    // the immediate-hit re-check); otherwise every happy-path arm would leak a
    // Task sleeping until `deadline`, the opposite of the "zero wake-ups" goal.
    var backstop: Task<Void, Never>?
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let once = ResumeOnce()
        // Arm tracking over whatever observable state the predicate reads. The
        // `onChange` fires once, during the willSet of the first such property
        // to change; the awaiting task then resumes and the outer loop
        // re-checks (by which point the setter has completed).
        withObservationTracking {
            _ = predicate()
        } onChange: {
            once.fire { cont.resume() }
        }
        // Close the arm-vs-change race: a change may have landed between the
        // outer while-check and arming. If the predicate already holds, resume
        // now so the loop re-checks instead of waiting for a change that may
        // never come.
        if predicate() {
            once.fire { cont.resume() }
            return
        }
        // Backstop: resume at the deadline so a genuinely stuck condition fails
        // the wait instead of hanging.
        backstop = Task { @MainActor in
            try? await Task.sleep(until: deadline, clock: ContinuousClock())
            once.fire { cont.resume() }
        }
    }
    // Resolved (observation, immediate hit, or the backstop itself) — cancel the
    // backstop so it doesn't linger asleep until `deadline`.
    backstop?.cancel()
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
