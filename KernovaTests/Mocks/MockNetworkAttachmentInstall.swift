import Synchronization
import Virtualization
@testable import Kernova

/// Scripted stand-in for `NetworkAttachmentInstalling`, so handle tests drive
/// the queue-side install outcome without the live VM a `VMSession` needs.
final class MockNetworkAttachmentInstall: NetworkAttachmentInstalling {
    private let state = Mutex(State())

    private struct State {
        var buildFailureHandlers: [@Sendable () -> Void] = []
        var detachCount = 0
    }

    /// One entry per `applyNetworkAttachment` call, in order.
    var applyCount: Int { state.withLock { $0.buildFailureHandlers.count } }
    var detachCount: Int { state.withLock { $0.detachCount } }

    func applyNetworkAttachment(
        _ make: @escaping @Sendable () -> VZNetworkDeviceAttachment?,
        onBuildFailure: @escaping @Sendable () -> Void
    ) {
        state.withLock { $0.buildFailureHandlers.append(onBuildFailure) }
    }

    func detachNetworkAttachment() {
        state.withLock { $0.detachCount += 1 }
    }

    /// Reports the install of the apply at `index` as having found nothing to
    /// build, the outcome VZ leaves detached.
    func reportBuildFoundNothing(ofApplyAt index: Int) {
        state.withLock { $0.buildFailureHandlers[index] }()
    }
}
