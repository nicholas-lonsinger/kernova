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
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        var config = VMConfiguration(
            name: name, guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        mutate(&config)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        return VMInstance(
            configuration: config, bundleURL: bundleURL, phase: phase, preferences: preferences)
    }
}
