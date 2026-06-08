import Foundation

/// Abstraction for VM lifecycle operations (start, stop, pause, resume, save).
///
/// Restore is internal to `start`/`resume`: when a save file exists they fall
/// through to the private `restoreOrColdBoot` path rather than exposing a
/// separate restore entry point.
@MainActor
protocol VirtualizationProviding: Sendable {
    /// Starts a virtual machine.
    ///
    /// When `bootIntoRecovery` is `true` and the guest is macOS, the VM
    /// cold-boots into the macOS Recovery environment for this launch only (a
    /// one-shot `VZMacOSVirtualMachineStartOptions.startUpFromMacOSRecovery`).
    /// It is ignored for Linux guests and for restore-from-save paths.
    func start(_ instance: VMInstance, bootIntoRecovery: Bool) async throws
    func stop(_ instance: VMInstance) throws
    func forceStop(_ instance: VMInstance) async throws
    func pause(_ instance: VMInstance) async throws
    func resume(_ instance: VMInstance) async throws
    func save(_ instance: VMInstance) async throws
}
