import AppKit
import os

/// The copy one guest-setup flow gives ``GuestSetupProgressViewController``.
///
/// The steps themselves come from the VM's ``GuestSetupState``; this is what
/// stays fixed for the whole run, plus the per-step wording the state has no
/// business carrying.
struct GuestSetupDescriptor: Sendable, Equatable {
    private static let logger = Logger(subsystem: "app.kernova", category: "GuestSetupDescriptor")

    /// The image above the title, which is a template symbol for some flows and
    /// an AppKit system image for others.
    enum Icon: Sendable, Equatable {
        case named(NSImage.Name)
        case symbol(String)
    }

    /// Wording that depends on which step is running.
    struct StepCopy: Sendable, Equatable {
        /// Verb the subtitle's first line leads with ("Downloading").
        let detailVerb: String
    }

    let title: String
    let icon: Icon
    let stepCopy: [SetupStepID: StepCopy]

    /// The copy for `step`.
    func copy(for step: SetupStepID) -> StepCopy {
        guard let copy = stepCopy[step] else {
            Self.logger.fault(
                "No setup copy for step '\(step.rawValue, privacy: .public)' under '\(self.title, privacy: .public)'"
            )
            assertionFailure("No setup copy for step '\(step.rawValue)' under '\(title)'")
            return StepCopy(detailVerb: "Working")
        }
        return copy
    }

    // MARK: - Flows

    /// The macOS install: a restore image downloaded (unless it is already on
    /// disk), then written into the VM.
    static let macOSInstall = GuestSetupDescriptor(
        title: "Installing macOS",
        icon: .named(NSImage.computerName),
        stepCopy: [
            .download: StepCopy(detailVerb: "Downloading"),
            .install: StepCopy(detailVerb: "Installing macOS"),
        ])

    /// A Linux installer image: downloaded from where it is served, then
    /// checked against the digest published or supplied for it.
    static func linuxImage(named image: String) -> GuestSetupDescriptor {
        GuestSetupDescriptor(
            title: "Downloading \(image)",
            icon: .symbol("opticaldisc"),
            stepCopy: [
                .download: StepCopy(detailVerb: "Downloading"),
                .verify: StepCopy(detailVerb: "Verifying"),
            ])
    }

    /// The descriptor for whichever setup `instance` has pending.
    @MainActor static func forSetup(of instance: VMInstance) -> GuestSetupDescriptor {
        guard let context = instance.configuration.linuxInstallContext else { return .macOSInstall }
        return .linuxImage(named: context.imageDisplayName)
    }
}
