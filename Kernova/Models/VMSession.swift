import Foundation
import Virtualization
import os

// MARK: - Session Events

/// A lifecycle event VZ delivered on a session's queue.
enum VMSessionEvent: Sendable {
    case guestDidStop
    case didStopWithError(any Error)
    case networkAttachmentDisconnected(any Error)
}

/// The sink a session delivers its events into.
///
/// Called on the session's queue with the session's `id`, so the receiver can
/// hop to the main actor and drop events from a session it no longer holds.
struct VMSessionEvents: Sendable {
    let handle: @Sendable (UUID, VMSessionEvent) -> Void
}

// MARK: - Display Handle

/// Carries a `VZVirtualMachine` from its session to the one main-actor site
/// allowed to touch it: `VZVirtualMachineView.virtualMachine`.
///
/// `VZVirtualMachineView.h` (macOS 27.0) provides `VZVirtualMachineViewAdaptor`
/// for exactly this hand-off, because "VZVirtualMachine operates on a specific
/// dispatch queue and is not Sendable"; below a 27.0 deployment target the same
/// crossing is spelled `@unchecked Sendable`. This type is that one greppable
/// crossing — a one-line swap once the deployment target reaches 27.0.
struct VMDisplayHandle: @unchecked Sendable {
    private let vm: VZVirtualMachine

    init(vm: VZVirtualMachine) {
        self.vm = vm
    }

    /// Shows the session's VM in `view`, assigning only when it isn't already.
    @MainActor
    func attach(to view: VZVirtualMachineView) {
        if view.virtualMachine !== vm {
            view.virtualMachine = vm
        }
    }

    /// Clears whatever VM `view` is showing.
    @MainActor
    static func detach(_ view: VZVirtualMachineView) {
        view.virtualMachine = nil
    }
}

// MARK: - Session Errors

/// Failures `VMSession`'s device operations report; the calling service maps
/// them onto its user-facing error type.
enum VMSessionError: Error {
    case usbControllerUnavailable
    case usbDeviceNotFound
}

// MARK: - VMSession

/// One VM's isolation domain: the only type that holds a `VZVirtualMachine` or
/// any of its device objects, executing on the serial queue the VM was created
/// with.
///
/// `VZVirtualMachine.queue`'s documentation states the rule this actor
/// enforces: "Other properties or function calls on VZVirtualMachine must
/// happen on this queue. The framework also invokes any completion handlers
/// from asynchronous functions on this queue."
actor VMSession {
    /// The queue this VM was created with, and this actor's executor.
    nonisolated let queue: DispatchSerialQueue

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Session identity, carried by every delivered event so the owner can
    /// drop events from a session it has already replaced.
    nonisolated let id: UUID

    nonisolated let displayHandle: VMDisplayHandle

    // Configuration facts snapshotted at creation, so main-actor guards on
    // device presence stay synchronous.
    nonisolated let hasVirtioSocketDevice: Bool
    nonisolated let hasNetworkDevice: Bool
    nonisolated let hasUSBController: Bool

    private let vm: VZVirtualMachine

    /// VZ holds its delegate weakly; the session retains it.
    private let delegateAdapter: VMDelegateAdapter

    private static let logger = Logger(subsystem: "app.kernova", category: "VMSession")

    private init(id: UUID, queue: DispatchSerialQueue, vm: VZVirtualMachine, delegateAdapter: VMDelegateAdapter) {
        self.id = id
        self.queue = queue
        self.vm = vm
        self.delegateAdapter = delegateAdapter
        self.displayHandle = VMDisplayHandle(vm: vm)
        self.hasVirtioSocketDevice = vm.socketDevices.contains { $0 is VZVirtioSocketDevice }
        self.hasNetworkDevice = !vm.networkDevices.isEmpty
        self.hasUSBController = !vm.usbControllers.isEmpty
    }

    /// Creates the `VZVirtualMachine` on its own serial queue and wraps it in
    /// a session delivering into `events`.
    static func make(configuration: VZVirtualMachineConfiguration, events: VMSessionEvents) async -> VMSession {
        let id = UUID()
        let queue = DispatchSerialQueue(label: "app.kernova.vm.\(id.uuidString)", qos: .userInteractive)
        nonisolated(unsafe) let configuration = configuration
        return await withCheckedContinuation { continuation in
            queue.async {
                // `nonisolated(unsafe)`: both are born here and handed to the
                // actor whole — the `vm.delegate` reference between them is
                // what region analysis cannot see through.
                nonisolated(unsafe) let vm = VZVirtualMachine(configuration: configuration, queue: queue)
                assert(vm.queue === queue)
                nonisolated(unsafe) let adapter = VMDelegateAdapter(sessionID: id, events: events)
                vm.delegate = adapter
                continuation.resume(
                    returning: VMSession(id: id, queue: queue, vm: vm, delegateAdapter: adapter))
            }
        }
    }

    // MARK: - Lifecycle

    func start(options: sending VZVirtualMachineStartOptions?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if let options {
                vm.start(options: options) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            } else {
                vm.start { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    /// Forcefully terminates the VM.
    func stop() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            vm.stop { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Requests a graceful ACPI shutdown.
    func requestStop() throws {
        try vm.requestStop()
    }

    func pause() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            vm.pause { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Pauses only when the VM is running — a save's precondition, answered
    /// and acted on in one hop so no state can move in between.
    func pauseIfRunning() async throws {
        guard vm.state == .running else { return }
        try await pause()
    }

    func resume() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            vm.resume { result in
                continuation.resume(with: result)
            }
        }
    }

    func saveMachineState(to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            vm.saveMachineStateTo(url: url) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func restoreMachineState(from url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            vm.restoreMachineStateFrom(url: url) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Waits for the VM to reach `.stopped`, the timeout to elapse, or the
    /// surrounding `Task` to be cancelled — whichever comes first.
    ///
    /// Never throws; outer cancellation only suppresses the timeout warning.
    /// Bridges `vm.state`'s KVO through `NSObject.observe(_:options:)` rather
    /// than Combine's `publisher(for:).values`, whose `AsyncPublisher` isn't
    /// `Sendable` when its subject isn't — and the sequence has to cross into
    /// a task-group child.
    func waitUntilStopped(timeout: Duration) async {
        // Quick path for the common case where VZ propagated synchronously.
        if vm.state == .stopped { return }

        let (stream, continuation) = AsyncStream<Void>.makeStream()

        // The `defer { invalidate() }` below keeps the observation alive for
        // the lifetime of this function; losing the reference silently stops it.
        let observation = vm.observe(\.state, options: [.new]) { observed, _ in
            if observed.state == .stopped {
                continuation.yield(())
                continuation.finish()
            }
        }
        defer { observation.invalidate() }

        // Cover the race: state may have transitioned to `.stopped` between
        // the initial guard and observer registration above.
        if vm.state == .stopped {
            continuation.finish()
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // `for await` over `AsyncStream` returns when the consumer's
                // task is cancelled, so `group.cancelAll()` below unblocks this
                // child without further plumbing.
                for await _ in stream { return }
            }
            group.addTask {
                // `try?`: when the group cancels this child the sleep throws,
                // and exiting silently is what lets the group complete.
                try? await Task.sleep(for: timeout)
            }
            _ = await group.next()
            group.cancelAll()
        }

        // A timeout is an anomaly; a user cancel is not. Log only the former.
        if vm.state != .stopped && !Task.isCancelled {
            Self.logger.warning(
                "VM did not reach .stopped within timeout (state: \(String(describing: self.vm.state), privacy: .public))"
            )
        }
    }

    // MARK: - macOS Installation

    /// Runs `VZMacOSInstaller` against this VM, reporting fractional progress
    /// through `onProgress` (called off the main actor).
    ///
    /// `VZMacOSInstaller.h` requires both
    /// `init(virtualMachine:restoringFromImageAt:)` and `install` to be called
    /// on the virtual machine's queue — this method is where Kernova satisfies
    /// that.
    func installMacOS(from url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: url)

        let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            onProgress(progress.fractionCompleted)
        }
        defer { observation.invalidate() }

        // Capture progress for the @Sendable onCancel closure (VZMacOSInstaller
        // is not Sendable).
        let installerProgress = installer.progress

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                installer.install { result in
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            installerProgress.cancel()
        }
    }

    // MARK: - Vsock Listeners

    /// Installs `host`'s listener on the VM's virtio socket device.
    func attach(_ host: VsockListenerHost) {
        guard let device = virtioSocketDevice() else { return }
        host.attach(to: device)
    }

    /// Installs every listener in `hosts` in one hop.
    func attach(_ hosts: [VsockListenerHost]) {
        guard let device = virtioSocketDevice() else { return }
        for host in hosts {
            host.attach(to: device)
        }
    }

    func removeSocketListener(port: UInt32) {
        virtioSocketDevice()?.removeSocketListener(forPort: port)
    }

    private func virtioSocketDevice() -> VZVirtioSocketDevice? {
        guard
            let device = vm.socketDevices.first(where: { $0 is VZVirtioSocketDevice })
                as? VZVirtioSocketDevice
        else {
            Self.logger.fault("Socket-device call on a session with no VZVirtioSocketDevice")
            assertionFailure("Callers must guard on hasVirtioSocketDevice")
            return nil
        }
        return device
    }

    // MARK: - USB Devices

    /// Builds a USB mass storage device on the queue via `make` and attaches
    /// it on the XHCI controller.
    ///
    /// - Returns: The attached device's UUID.
    func attachUSBDevice(_ make: @Sendable () throws -> VZUSBMassStorageDevice) async throws -> UUID {
        let controller = try usbController()
        let device = try make()
        let uuid = device.uuid
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            controller.attach(device: device) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        return uuid
    }

    /// Detaches the USB device carrying `uuid`, throwing
    /// `VMSessionError.usbDeviceNotFound` when the controller doesn't hold it.
    func detachUSBDevice(uuid: UUID) async throws {
        let controller = try usbController()
        guard let device = controller.usbDevices.first(where: { $0.uuid == uuid }) else {
            throw VMSessionError.usbDeviceNotFound
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            controller.detach(device: device) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func usbController() throws -> VZUSBController {
        guard let controller = vm.usbControllers.first else {
            Self.logger.fault("USB call on a session with no USB controller")
            assertionFailure("Callers must guard on hasUSBController")
            throw VMSessionError.usbControllerUnavailable
        }
        return controller
    }

    // MARK: - Network Device

    /// The VM's current network attachment, classified by `classify` on the
    /// queue so the VZ object never leaves it.
    func inspectNetworkAttachment<T: Sendable>(
        _ classify: @Sendable (VZNetworkDeviceAttachment) -> T?
    ) -> T? {
        guard let attachment = vm.networkDevices.first?.attachment else { return nil }
        return classify(attachment)
    }

    /// Builds an attachment on the queue via `make` and installs it on the
    /// VM's network device.
    ///
    /// Fire-and-forget by design, and `nonisolated` so callers enqueue in
    /// program order without suspending: an attachment install reports failure
    /// only asynchronously, through a later disconnect callback, so there is
    /// nothing to await. `make` returning `nil` detaches the device — the
    /// honest state when what the caller's feasibility check saw vanished
    /// before this write ran — and `onBuildFailure` runs on the queue so the
    /// caller can follow the device into detached.
    nonisolated func applyNetworkAttachment(
        _ make: @escaping @Sendable () -> VZNetworkDeviceAttachment?,
        onBuildFailure: @escaping @Sendable () -> Void
    ) {
        queue.async {
            self.assumeIsolated { session in
                guard let device = session.vm.networkDevices.first else {
                    Self.logger.fault("Network attachment install on a session with no network device")
                    assertionFailure("Callers must guard on hasNetworkDevice")
                    return
                }
                let attachment = make()
                device.attachment = attachment
                if attachment == nil {
                    Self.logger.warning(
                        "Network attachment could not be built at install time — leaving the device detached"
                    )
                    onBuildFailure()
                }
            }
        }
    }

    /// Detaches the VM's network device. Same ordered fire-and-forget contract
    /// as ``applyNetworkAttachment(_:onBuildFailure:)``.
    nonisolated func detachNetworkAttachment() {
        queue.async {
            self.assumeIsolated { session in
                session.vm.networkDevices.first?.attachment = nil
            }
        }
    }
}

// MARK: - Delegate Adapter

/// Receives `VZVirtualMachineDelegate` callbacks on the session's queue and
/// forwards them as events. Reads nothing from the VM — no isolation
/// assumption needed.
private final class VMDelegateAdapter: NSObject, VZVirtualMachineDelegate {
    private let sessionID: UUID
    private let events: VMSessionEvents

    init(sessionID: UUID, events: VMSessionEvents) {
        self.sessionID = sessionID
        self.events = events
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        events.handle(sessionID, .guestDidStop)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        events.handle(sessionID, .didStopWithError(error))
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: any Error
    ) {
        events.handle(sessionID, .networkAttachmentDisconnected(error))
    }
}
