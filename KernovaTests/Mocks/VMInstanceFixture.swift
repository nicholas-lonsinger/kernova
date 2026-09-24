import Foundation
@testable import Kernova

/// The unregistered counterpart to ``RegisteredVMInstanceFixture`` — a
/// `VMInstance` on a temporary-directory bundle, with nothing wired into a
/// library.
@MainActor
enum VMInstanceFixture {
    /// The bundle URL is derived from the configuration `mutate` leaves behind.
    static func make(
        name: String = "Test VM",
        guestOS: VMGuestOS = .linux,
        phase: VMLifecyclePhase = .stopped,
        preferences: AppPreferences = .shared,
        hostState: VMHostState = VMHostState(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        var config = VMConfiguration(
            name: name, guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        mutate(&config)
        return VMInstance(
            configuration: config, bundleURL: bundleURL(for: config.id), phase: phase,
            hostState: hostState, preferences: preferences)
    }

    /// The bundle a fixture VM with identifier `id` lives at — for a
    /// configuration that names paths inside it before the instance exists.
    nonisolated static func bundleURL(for id: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(id.uuidString).kernova", isDirectory: true)
    }

    /// Puts a suspend slot in `instance`'s bundle, creating the bundle
    /// directory — what every predicate that follows the file reads
    /// (``VMInstance/holdsSuspendedSession``).
    ///
    /// The bundle is a real directory under the temporary directory, so a test
    /// that writes one takes it away again with ``removeBundle(of:)``.
    static func writeSaveFile(for instance: VMInstance) throws {
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        try Data("suspend slot".utf8).write(to: instance.saveFileURL)
    }

    /// Takes away the bundle directory a fixture wrote into.
    static func removeBundle(of instance: VMInstance) {
        try? FileManager.default.removeItem(at: instance.bundleURL)
    }
}
