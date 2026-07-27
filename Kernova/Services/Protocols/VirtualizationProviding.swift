import Foundation

/// Abstraction for VM lifecycle operations (start, stop, pause, resume, save).
///
/// Restore has no entry point of its own — `start` and `resume` restore from a
/// save file when one exists.
@MainActor
protocol VirtualizationProviding: Sendable {
    /// Starts a virtual machine.
    ///
    /// `bootIntoRecovery` cold-boots a macOS guest into Recovery for this launch
    /// only; it is ignored for Linux guests and for restore-from-save paths.
    func start(_ instance: VMInstance, bootIntoRecovery: Bool) async throws
    func stop(_ instance: VMInstance) throws
    func forceStop(_ instance: VMInstance) async throws
    func pause(_ instance: VMInstance) async throws
    func resume(_ instance: VMInstance) async throws
    func save(_ instance: VMInstance) async throws
}
