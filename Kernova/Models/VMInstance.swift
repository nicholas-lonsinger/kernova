import Foundation
import os
import Virtualization

/// The VM display's current hosting location.
enum VMDisplayMode: Sendable {
    /// Display is embedded in the main window's detail pane.
    case inline
    /// Display is in its own resizable window (not fullscreen).
    case popOut
    /// Display is in its own window in native macOS fullscreen.
    case fullscreen
}

/// Runtime wrapper around a VM configuration, its backing virtual machine, and current status.
@MainActor
@Observable
final class VMInstance: Identifiable {

    // MARK: - Properties

    let instanceID: UUID
    var configuration: VMConfiguration
    var status: VMStatus
    var virtualMachine: VZVirtualMachine?
    let bundleURL: URL

    /// Structured installation state tracking download and install phases.
    var installState: MacOSInstallState?

    /// Handle to the in-flight macOS installation task, enabling cooperative cancellation.
    var installTask: Task<Void, Never>?

    // MARK: - Preparing State (Clone/Import)

    /// Describes the kind of long-running preparation operation in progress
    /// and provides all associated user-facing strings (display labels, cancel labels, alert titles).
    enum PreparingOperation: Sendable {
        case cloning
        case importing

        var displayLabel: String {
            switch self {
            case .cloning: "Cloning\u{2026}"
            case .importing: "Importing\u{2026}"
            }
        }

        var cancelLabel: String {
            switch self {
            case .cloning: "Cancel Clone"
            case .importing: "Cancel Import"
            }
        }

        var cancelAlertTitle: String {
            switch self {
            case .cloning: "Cancel Clone?"
            case .importing: "Cancel Import?"
            }
        }
    }

    /// Tracks an in-flight clone or import operation. Non-nil when this instance is a
    /// "phantom row" awaiting a file copy to finish (see `VMLibraryViewModel`).
    struct PreparingState {
        let operation: PreparingOperation
        var task: Task<Void, Never>
    }

    /// Non-nil when this instance is a phantom row awaiting a clone or import to finish.
    var preparingState: PreparingState?

    /// Convenience: `true` when a preparing operation is in progress.
    var isPreparing: Bool { preparingState != nil }

    /// Error message if the VM entered an error state.
    var errorMessage: String?

    /// Where the VM display is currently hosted (inline, pop-out window, or fullscreen).
    var displayMode: VMDisplayMode = .inline

    // MARK: - Clipboard Sharing

    /// Bidirectional pipes for the SPICE clipboard console port.
    var clipboardInputPipe: Pipe?
    var clipboardOutputPipe: Pipe?

    /// The SPICE clipboard service managing protocol I/O for this VM.
    var clipboardService: SpiceClipboardService?

    // MARK: - Serial Console

    /// Observable text buffer driven by serial port output. Capped at 1 MB in memory;
    /// full history is preserved on disk in `serial.log`.
    var serialOutputText: String = ""

    /// Bidirectional pipes for serial port communication.
    var serialInputPipe: Pipe?
    var serialOutputPipe: Pipe?

    /// File handle for writing serial output to the on-disk log.
    private var serialLogFileHandle: FileHandle?

    /// Serial queue for pipe writes, keeping the main thread free if the guest
    /// stops reading and the kernel buffer fills up.
    private let serialInputQueue = DispatchQueue(label: "com.kernova.serial-input", qos: .userInteractive)

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMInstance")

    /// Maximum in-memory serial buffer size (1 MB).
    private static let maxSerialBufferSize = 1_000_000

    nonisolated var id: UUID { instanceID }
    var name: String { configuration.name }

    // MARK: - Delegate

    private var delegateAdapter: VMDelegateAdapter?

    // MARK: - Bundle Layout

    let bundleLayout: VMBundleLayout

    /// Cached on-disk usage for the VM's disk image, populated asynchronously
    /// by `refreshDiskUsage()` to avoid blocking the main thread.
    var cachedDiskUsageBytes: UInt64?

    /// Reads the physical disk usage off the main thread and caches the result.
    func refreshDiskUsage() async {
        let layout = bundleLayout
        let usage = await Task.detached { layout.diskUsageBytes }.value
        cachedDiskUsageBytes = usage
        Self.logger.debug("Refreshed disk usage for '\(self.name, privacy: .public)': \(usage.map { "\($0) bytes" } ?? "nil", privacy: .public)")
    }

    // MARK: - Initializer

    init(configuration: VMConfiguration, bundleURL: URL, status: VMStatus = .stopped) {
        self.instanceID = configuration.id
        self.configuration = configuration
        self.bundleURL = bundleURL
        self.bundleLayout = VMBundleLayout(bundleURL: bundleURL)
        self.status = status
    }

    // MARK: - VM Bundle Paths (forwarded from VMBundleLayout)

    var diskImageURL: URL { bundleLayout.diskImageURL }
    var auxiliaryStorageURL: URL { bundleLayout.auxiliaryStorageURL }
    var hardwareModelURL: URL { bundleLayout.hardwareModelURL }
    var machineIdentifierURL: URL { bundleLayout.machineIdentifierURL }
    var saveFileURL: URL { bundleLayout.saveFileURL }
    var hasSaveFile: Bool { bundleLayout.hasSaveFile }
    var serialLogURL: URL { bundleLayout.serialLogURL }
    var diskUsageBytes: UInt64? { bundleLayout.diskUsageBytes }

    // MARK: - Runtime USB Devices

    /// USB mass storage devices currently attached via the XHCI controller.
    /// Populated at runtime only; cleared on VM stop/teardown.
    var attachedUSBDevices: [USBDeviceInfo] = []

    /// `true` when the VM has a live `VZVirtualMachine` in a running or paused state, enabling USB hot-plug via the XHCI controller.
    var canAttachUSBDevices: Bool {
        (status == .running || status == .paused) && virtualMachine != nil
    }

    /// `true` when the VM is paused-to-disk but has no live `VZVirtualMachine` in memory.
    var isColdPaused: Bool {
        status == .paused && virtualMachine == nil
    }

    /// `true` when this VM should keep the app alive: preparing, in an active lifecycle
    /// state, or live-paused in memory (as opposed to cold-paused to disk).
    var isKeepingAppAlive: Bool {
        isPreparing || status.isActive || (status == .paused && virtualMachine != nil)
    }

    /// `true` when the VM is eligible for graceful stop (running or live-paused, not cold-paused).
    var canStop: Bool {
        status.canStop && !isColdPaused
    }

    /// `true` when the VM is eligible to save state (active + live VM, not cold-paused).
    var canSave: Bool {
        status.canSave && !isColdPaused
    }

    /// `true` when the VM is eligible to pop out or enter fullscreen (active status + live VM).
    var canUseExternalDisplay: Bool {
        (status == .running || status == .paused) && virtualMachine != nil
    }

    /// `true` when this VM's display is shown in a dedicated fullscreen window.
    var isInFullscreen: Bool { displayMode == .fullscreen }

    /// `true` when the display is in any separate window (pop-out or fullscreen).
    var isInSeparateWindow: Bool { displayMode != .inline }

    /// `true` when the VM is eligible to show a serial console window (active status + live VM).
    var canShowSerialConsole: Bool {
        (status == .running || status == .paused) && virtualMachine != nil
    }

    /// `true` when the VM has clipboard sharing enabled and is eligible to show the clipboard window.
    var canShowClipboard: Bool {
        configuration.clipboardSharingEnabled && (status == .running || status == .paused) && virtualMachine != nil
    }

    // MARK: - Delegate Setup

    func setupDelegate() {
        guard let vm = virtualMachine else { return }
        let adapter = VMDelegateAdapter(instance: self)
        vm.delegate = adapter
        self.delegateAdapter = adapter
    }

    // MARK: - State Helpers

    /// Tears down the live VM session: stops serial I/O, releases pipes, and
    /// clears the `VZVirtualMachine` reference. Does **not** change `status` —
    /// callers set the appropriate status after calling this.
    func tearDownSession() {
        stopClipboardService()
        stopSerialReading()
        serialInputPipe = nil
        serialOutputPipe = nil
        attachedUSBDevices = []
        virtualMachine = nil
        delegateAdapter = nil
    }

    /// Releases the VZVirtualMachine reference and marks the VM as stopped.
    func resetToStopped() {
        tearDownSession()
        status = .stopped
    }

    /// Creates a VZVirtualMachine, assigns it, and wires up the delegate. Returns the VM.
    @discardableResult
    func attachVirtualMachine(from vzConfig: VZVirtualMachineConfiguration) -> VZVirtualMachine {
        let vm = VZVirtualMachine(configuration: vzConfig)
        virtualMachine = vm
        setupDelegate()
        return vm
    }

    /// Removes the persisted save file from the bundle, if it exists.
    func removeSaveFile() {
        do {
            try FileManager.default.removeItem(at: saveFileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            // File already absent — expected in some flows
        } catch {
            Self.logger.warning("Failed to remove save file for '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Serial Console I/O

    /// Begins reading from the serial output pipe. Output is appended to
    /// `serialOutputText` (for the UI) and written to the on-disk log file.
    func startSerialReading() {
        guard let outputPipe = serialOutputPipe else { return }

        // Clear text buffer for a fresh session
        serialOutputText = ""

        // Open (or create) the log file for appending
        let logURL = serialLogURL
        if !FileManager.default.fileExists(atPath: logURL.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: logURL)
            do { _ = try handle.seekToEnd() } catch {
                Self.logger.warning("Could not seek to end of serial log: \(error.localizedDescription, privacy: .public)")
            }
            serialLogFileHandle = handle
        } catch {
            Self.logger.warning("Could not open serial log for writing: \(error.localizedDescription, privacy: .public)")
        }

        // Capture for the readability handler closure (runs on a background GCD queue)
        let logFileHandle = serialLogFileHandle
        let logger = Self.logger

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Write to disk log (background-safe — FileHandle is thread-safe for sequential writes)
            do {
                try logFileHandle?.write(contentsOf: data)
            } catch {
                logger.error("Failed to write to serial log: \(error.localizedDescription, privacy: .public)")
            }

            // Update UI buffer on the main actor
            if let text = String(data: data, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.serialOutputText.append(text)

                    // Cap in-memory buffer at 1 MB
                    if self.serialOutputText.utf8.count > Self.maxSerialBufferSize {
                        let overflow = self.serialOutputText.utf8.count - Self.maxSerialBufferSize
                        let idx = self.serialOutputText.utf8.index(
                            self.serialOutputText.startIndex,
                            offsetBy: overflow
                        )
                        self.serialOutputText = String(self.serialOutputText[idx...])
                    }
                }
            }
        }

        Self.logger.info("Serial reading started for '\(self.name, privacy: .public)'")
    }

    /// Sends a string to the guest via the serial input pipe.
    ///
    /// The write is dispatched to a dedicated serial queue so that a full
    /// kernel pipe buffer (~64 KB on macOS) never blocks the main thread.
    func sendSerialInput(_ string: String) {
        guard let data = string.data(using: .utf8),
              let inputPipe = serialInputPipe else { return }
        let fileHandle = inputPipe.fileHandleForWriting
        let vmName = self.name
        let logger = Self.logger
        // inputPipe is captured strongly so its file descriptors remain valid
        // even if tearDownSession() nils the instance property mid-write.
        serialInputQueue.async { [inputPipe] in
            do {
                try fileHandle.write(contentsOf: data)
            } catch {
                logger.error("Failed to send serial input to VM '\(vmName, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
            withExtendedLifetime(inputPipe) {}
        }
    }

    /// Stops reading from the serial output pipe and closes the log file handle.
    func stopSerialReading() {
        serialOutputPipe?.fileHandleForReading.readabilityHandler = nil
        do {
            try serialLogFileHandle?.close()
        } catch {
            Self.logger.warning("Failed to close serial log file for VM '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
        serialLogFileHandle = nil
    }

    // MARK: - Clipboard Service Lifecycle

    /// Creates and starts the SPICE clipboard service using the clipboard pipes.
    func startClipboardService() {
        guard configuration.clipboardSharingEnabled else { return }

        guard let inputPipe = clipboardInputPipe,
              let outputPipe = clipboardOutputPipe else {
            Self.logger.error("Clipboard sharing enabled but pipes not configured for '\(self.name, privacy: .public)'")
            return
        }

        let service = SpiceClipboardService(inputPipe: inputPipe, outputPipe: outputPipe)
        service.start()
        clipboardService = service
        Self.logger.info("Clipboard service started for '\(self.name, privacy: .public)'")
    }

    /// Stops and releases the clipboard service and closes pipe file handles.
    func stopClipboardService() {
        clipboardService?.stop()
        clipboardService = nil
        try? clipboardInputPipe?.fileHandleForReading.close()
        try? clipboardInputPipe?.fileHandleForWriting.close()
        try? clipboardOutputPipe?.fileHandleForReading.close()
        try? clipboardOutputPipe?.fileHandleForWriting.close()
        clipboardInputPipe = nil
        clipboardOutputPipe = nil
    }
}

// MARK: - VZVirtualMachineDelegate Adapter

/// Bridges `VZVirtualMachineDelegate` callbacks to update the `VMInstance` status.
@MainActor
private final class VMDelegateAdapter: NSObject, VZVirtualMachineDelegate {
    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMDelegateAdapter")

    weak var instance: VMInstance?

    init(instance: VMInstance) {
        self.instance = instance
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated {
            guard let instance else {
                Self.logger.warning("guestDidStop received but VMInstance has been deallocated")
                return
            }
            instance.resetToStopped()
            Self.logger.notice("Guest stopped for VM '\(instance.name, privacy: .public)'")
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        MainActor.assumeIsolated {
            guard let instance else {
                Self.logger.warning("didStopWithError received but VMInstance has been deallocated")
                return
            }
            instance.tearDownSession()
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            Self.logger.error("VM '\(instance.name, privacy: .public)' stopped with error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
