import Foundation
import Synchronization
import Testing
import Virtualization

@testable import KernovaVirtualization

/// Scripted stand-in for `NetworkAttachmentInstalling`, so handle tests drive
/// the queue-side install outcome without the live VM a `VMSession` needs.
final class MockNetworkAttachmentInstall: NetworkAttachmentInstalling {
    private let state = Mutex(State())

    private struct Apply {
        var make: (@Sendable () -> VZNetworkDeviceAttachment?)?
        let onBuildFailure: @Sendable () -> Void
    }

    private struct State {
        var applies: [Apply] = []
        var detachCount = 0
    }

    /// One entry per `applyNetworkAttachment` call, in order.
    var applyCount: Int { state.withLock { $0.applies.count } }
    var detachCount: Int { state.withLock { $0.detachCount } }

    func applyNetworkAttachment(
        _ make: @escaping @Sendable () -> VZNetworkDeviceAttachment?,
        onBuildFailure: @escaping @Sendable () -> Void
    ) {
        state.withLock { $0.applies.append(Apply(make: make, onBuildFailure: onBuildFailure)) }
    }

    func detachNetworkAttachment() {
        state.withLock { $0.detachCount += 1 }
    }

    /// Runs the build of the apply at `index` once, as the session's queue
    /// does — reporting a build failure when it finds nothing — then drops
    /// that build. `nil` when it found nothing.
    func runBuild(ofApplyAt index: Int) -> VZNetworkDeviceAttachment? {
        let (make, onBuildFailure) = state.withLock { state in
            defer { state.applies[index].make = nil }
            return (state.applies[index].make, state.applies[index].onBuildFailure)
        }
        guard let make else {
            Issue.record("The build of apply \(index) already ran")
            return nil
        }
        let attachment = make()
        if attachment == nil { onBuildFailure() }
        return attachment
    }

    /// Reports the install of the apply at `index` as having found nothing to
    /// build, the outcome VZ leaves detached.
    func reportBuildFoundNothing(ofApplyAt index: Int) {
        state.withLock { $0.applies[index].onBuildFailure }()
    }
}
