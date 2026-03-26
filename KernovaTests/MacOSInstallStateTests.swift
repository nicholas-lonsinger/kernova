import Testing
import Foundation
@testable import Kernova

@Suite("MacOSInstallState Tests")
struct MacOSInstallStateTests {

    // MARK: - Initial State

    @Test("Initial state with download step starts in downloading phase")
    func initialStateWithDownload() {
        let state = MacOSInstallState(
            hasDownloadStep: true,
            currentPhase: .downloading(DownloadProgress(fraction: 0, bytesWritten: 0, totalBytes: 0, bytesPerSecond: 0))
        )

        #expect(state.hasDownloadStep == true)
        #expect(state.downloadCompleted == false)
        if case .downloading(let dl) = state.currentPhase {
            #expect(dl.fraction == 0)
            #expect(dl.bytesWritten == 0)
            #expect(dl.totalBytes == 0)
            #expect(dl.bytesPerSecond == 0)
        } else {
            Issue.record("Expected downloading phase")
        }
    }

    @Test("Initial state without download step starts in installing phase")
    func initialStateWithoutDownload() {
        let state = MacOSInstallState(
            hasDownloadStep: false,
            currentPhase: .installing(progress: 0)
        )

        #expect(state.hasDownloadStep == false)
        #expect(state.downloadCompleted == false)
        if case .installing(let progress) = state.currentPhase {
            #expect(progress == 0)
        } else {
            Issue.record("Expected installing phase")
        }
    }

    // MARK: - Phase Transitions

    @Test("Phase transitions from downloading to installing")
    func phaseTransition() {
        var state = MacOSInstallState(
            hasDownloadStep: true,
            currentPhase: .downloading(DownloadProgress(fraction: 0, bytesWritten: 0, totalBytes: 1000, bytesPerSecond: 0))
        )

        // Simulate download completion
        state.downloadCompleted = true
        state.currentPhase = .installing(progress: 0)

        #expect(state.downloadCompleted == true)
        if case .installing(let progress) = state.currentPhase {
            #expect(progress == 0)
        } else {
            Issue.record("Expected installing phase after transition")
        }
    }

    // MARK: - Progress Tracking

    @Test("Download progress tracks bytes written and total")
    func downloadProgress() {
        var state = MacOSInstallState(
            hasDownloadStep: true,
            currentPhase: .downloading(DownloadProgress(fraction: 0, bytesWritten: 0, totalBytes: 1_000_000, bytesPerSecond: 0))
        )

        state.currentPhase = .downloading(DownloadProgress(
            fraction: 0.5,
            bytesWritten: 500_000,
            totalBytes: 1_000_000,
            bytesPerSecond: 42_500_000
        ))

        if case .downloading(let dl) = state.currentPhase {
            #expect(dl.fraction == 0.5)
            #expect(dl.bytesWritten == 500_000)
            #expect(dl.totalBytes == 1_000_000)
            #expect(dl.bytesPerSecond == 42_500_000)
        } else {
            Issue.record("Expected downloading phase")
        }
    }

    @Test("Install progress tracks completion percentage")
    func installProgress() {
        var state = MacOSInstallState(
            hasDownloadStep: false,
            currentPhase: .installing(progress: 0)
        )

        state.currentPhase = .installing(progress: 0.75)

        if case .installing(let progress) = state.currentPhase {
            #expect(progress == 0.75)
        } else {
            Issue.record("Expected installing phase")
        }
    }
}
