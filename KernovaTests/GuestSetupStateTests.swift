import Foundation
import Testing

@testable import Kernova

@Suite("GuestSetupState Tests")
struct GuestSetupStateTests {
    // MARK: - macOS install flow

    @Test("A macOS install with a download step starts on Download")
    func macOSInstallWithDownload() {
        let state = GuestSetupState.macOSInstall(hasDownloadStep: true)

        #expect(state.steps.map(\.id) == [.download, .install])
        #expect(state.steps.map(\.label) == ["Download", "Install"])
        #expect(state.currentStepIndex == 0)
        #expect(state.showsStepIndicator)
        #expect(state.state(ofStepAt: 0) == .active)
        #expect(state.state(ofStepAt: 1) == .pending)
        if case .download(let download) = state.progress {
            #expect(download == .zero)
        } else {
            Issue.record("Expected a download progress payload")
        }
    }

    @Test("A macOS install from a local image is a single Install step with no indicator")
    func macOSInstallWithoutDownload() {
        let state = GuestSetupState.macOSInstall(hasDownloadStep: false)

        #expect(state.steps.map(\.id) == [.install])
        #expect(!state.showsStepIndicator)
        #expect(state.state(ofStepAt: 0) == .active)
        #expect(state.progress == .fraction(0))
    }

    // MARK: - Linux image flow

    @Test("A Linux image download runs Download then Verify")
    func linuxImageSteps() {
        let state = GuestSetupState.linuxImage()

        #expect(state.steps.map(\.id) == [.download, .verify])
        #expect(state.steps.map(\.label) == ["Download", "Verify"])
        #expect(state.showsStepIndicator)
        #expect(state.progress == .download(.zero))
    }

    // MARK: - Step transitions

    @Test("Advancing completes the finished step and activates the next")
    func advanceMovesTheActiveStep() {
        var state = GuestSetupState.linuxImage()

        state.advance(progress: .fraction(0))

        #expect(state.currentStepIndex == 1)
        #expect(state.currentStep?.id == .verify)
        #expect(state.state(ofStepAt: 0) == .completed)
        #expect(state.state(ofStepAt: 1) == .active)
        #expect(state.progress == .fraction(0))
    }

    @Test("Progress updates in place without moving the step")
    func progressUpdatesInPlace() {
        var state = GuestSetupState.macOSInstall(hasDownloadStep: true)

        state.progress = .download(
            DownloadProgress(bytesWritten: 500_000, totalBytes: 1_000_000, bytesPerSecond: 42))

        #expect(state.currentStepIndex == 0)
        #expect(state.progress.fraction == 0.5)
    }

    @Test("currentStep is nil when the index names no step")
    func currentStepOutOfRange() {
        let state = GuestSetupState(
            steps: [SetupStep(id: .install, label: "Install")],
            currentStepIndex: 3,
            progress: .fraction(0))

        #expect(state.currentStep == nil)
    }

    // MARK: - Progress payloads

    @Test("A download payload reports the transfer's own fraction")
    func downloadFraction() {
        let progress = SetupStepProgress.download(
            DownloadProgress(bytesWritten: 750_000, totalBytes: 1_000_000, bytesPerSecond: 0))
        #expect(progress.fraction == 0.75)
    }

    @Test("A fraction payload reports itself")
    func plainFraction() {
        #expect(SetupStepProgress.fraction(0.42).fraction == 0.42)
    }

    @Test("A download of unknown length reports no progress rather than dividing by zero")
    func downloadFractionZeroTotal() {
        #expect(SetupStepProgress.download(.zero).fraction == 0)
    }
}
