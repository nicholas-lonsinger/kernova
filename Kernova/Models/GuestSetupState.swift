import Foundation
import os

/// Which piece of work a ``SetupStep`` stands for.
enum SetupStepID: String, Sendable, Equatable {
    case download
    case install
    case verify
}

/// One step of a guest-setup flow, as the progress indicator draws it.
struct SetupStep: Sendable, Equatable {
    let id: SetupStepID
    /// Name shown beside the step's circle.
    let label: String
}

/// How far the running step has got.
enum SetupStepProgress: Sendable, Equatable {
    /// A transfer, which reports a speed and an estimate alongside its fraction.
    case download(DownloadProgress)
    /// Completion alone, `0...1`.
    case fraction(Double)

    /// The value the progress bar shows.
    var fraction: Double {
        switch self {
        case .download(let download): download.fraction
        case .fraction(let value): value
        }
    }
}

/// How a step reads relative to the one running.
enum SetupStepState: Sendable, Equatable {
    case pending
    case active
    case completed
}

/// Runtime state of a multi-step guest setup — a macOS install, or a Linux
/// installer image fetched and checked against its published digest.
///
/// Never persisted: an interrupted setup resumes from the VM's install context,
/// which is what survives a relaunch.
struct GuestSetupState: Sendable, Equatable {
    private static let logger = Logger(subsystem: "app.kernova", category: "GuestSetupState")

    /// Every step this run will take, fixed for its duration so the indicator
    /// can be built once when the view mounts.
    let steps: [SetupStep]

    /// Index into ``steps`` of the step now running.
    private(set) var currentStepIndex: Int

    var progress: SetupStepProgress

    init(steps: [SetupStep], currentStepIndex: Int = 0, progress: SetupStepProgress) {
        self.steps = steps
        self.currentStepIndex = currentStepIndex
        self.progress = progress
    }

    /// The step now running, or `nil` when the index names none.
    var currentStep: SetupStep? {
        steps.indices.contains(currentStepIndex) ? steps[currentStepIndex] : nil
    }

    /// Whether to draw the step indicator at all: a single-step flow says
    /// nothing the progress bar doesn't already.
    var showsStepIndicator: Bool { steps.count > 1 }

    /// How the step at `index` reads relative to the one running.
    func state(ofStepAt index: Int) -> SetupStepState {
        if index < currentStepIndex { return .completed }
        if index == currentStepIndex { return .active }
        return .pending
    }

    /// Moves to the next step, seeding what it reports.
    mutating func advance(progress: SetupStepProgress) {
        guard currentStepIndex + 1 < steps.count else {
            // Read into locals: an `os.Logger` interpolation is an escaping
            // autoclosure, which cannot capture a mutating `self`.
            let index = currentStepIndex
            let count = steps.count
            Self.logger.fault(
                "Advanced past the last setup step (index \(index, privacy: .public) of \(count, privacy: .public))"
            )
            assertionFailure("Advanced past the last setup step: \(index) of \(count)")
            self.progress = progress
            return
        }
        currentStepIndex += 1
        self.progress = progress
    }

    // MARK: - Flows

    /// A macOS install: the image is downloaded first unless it is already on
    /// disk, then written into the VM.
    static func macOSInstall(hasDownloadStep: Bool) -> GuestSetupState {
        guard hasDownloadStep else {
            return GuestSetupState(
                steps: [SetupStep(id: .install, label: "Install")],
                progress: .fraction(0))
        }
        return GuestSetupState(
            steps: [
                SetupStep(id: .download, label: "Download"),
                SetupStep(id: .install, label: "Install"),
            ],
            progress: .download(.zero))
    }

    /// A Linux installer image: fetched from its mirror, then checked against
    /// the digest that mirror published for it.
    static func linuxImage() -> GuestSetupState {
        GuestSetupState(
            steps: [
                SetupStep(id: .download, label: "Download"),
                SetupStep(id: .verify, label: "Verify"),
            ],
            progress: .download(.zero))
    }
}
