import Foundation
import os
import Virtualization

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

    /// Error message if the VM entered an error state.
    var errorMessage: String?

    /// `true` when this VM's display is shown in a dedicated fullscreen window.
    var isInFullscreen: Bool = false

    // MARK: - Serial Console

    /// Observable text buffer driven by serial port output. Capped at 1 MB in memory;
    /// full history is preserved on disk in `serial.log`.
    var serialOutputText: String = ""

    /// Bidirectional pipes for serial port communication.
    var serialInputPipe: Pipe?
    var serialOutputPipe: Pipe?

    /// File handle for writing serial output to the on-disk log.
    private var serialLogFileHandle: FileHandle?

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMInstance")

    /// Maximum in-memory serial buffer size (1 MB).
    private static let maxSerialBufferSize = 1_000_000

    nonisolated var id: UUID { instanceID }
    var name: String { configuration.name }

    // MARK: - Delegate

    private var delegateAdapter: VMDelegateAdapter?

    // MARK: - Bundle Layout

    let bundleLayout: VMBundleLayout

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

    /// `true` when the VM is paused-to-disk but has no live `VZVirtualMachine` in memory.
    var isColdPaused: Bool {
        status == .paused && virtualMachine == nil
    }

    // MARK: - Delegate Setup

    func setupDelegate() {
        guard let vm = virtualMachine else { return }
        let adapter = VMDelegateAdapter(instance: self)
        vm.delegate = adapter
        self.delegateAdapter = adapter
    }

    // MARK: - State Helpers

    /// Releases the VZVirtualMachine reference and marks the VM as stopped.
    func resetToStopped() {
        stopSerialReading()
        serialInputPipe = nil
        serialOutputPipe = nil
        status = .stopped
        virtualMachine = nil
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
        try? FileManager.default.removeItem(at: saveFileURL)
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
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()
        serialLogFileHandle = logHandle

        // Capture for the readability handler closure (runs on a background GCD queue)
        let logFileHandle = logHandle

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Write to disk log (background-safe — FileHandle is thread-safe for sequential writes)
            logFileHandle?.write(data)

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

        Self.logger.info("Serial reading started for '\(self.name)'")
    }

    /// Sends a string to the guest via the serial input pipe.
    func sendSerialInput(_ string: String) {
        guard let data = string.data(using: .utf8),
              let inputPipe = serialInputPipe else { return }
        inputPipe.fileHandleForWriting.write(data)
    }

    /// Stops reading from the serial output pipe and closes the log file handle.
    func stopSerialReading() {
        serialOutputPipe?.fileHandleForReading.readabilityHandler = nil
        serialLogFileHandle?.closeFile()
        serialLogFileHandle = nil
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
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        MainActor.assumeIsolated {
            guard let instance else {
                Self.logger.warning("didStopWithError received but VMInstance has been deallocated")
                return
            }
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            instance.virtualMachine = nil
        }
    }
}
