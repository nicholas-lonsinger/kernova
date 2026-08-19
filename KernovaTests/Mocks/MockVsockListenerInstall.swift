import Synchronization

@testable import Kernova

/// Scripted stand-in for `VsockListenerInstalling`, so the live-policy tests
/// drive listener installs without the running VM a `VMSession` needs.
///
/// Records the ports of each call rather than the hosts: what the tests pin is
/// which ports move and which ones move together in one hop.
final class MockVsockListenerInstall: VsockListenerInstalling {
    private let state = Mutex(State())

    private struct State {
        var attached: [[UInt32]] = []
        var detached: [[UInt32]] = []
    }

    /// One entry per `attach` call, in order, holding that call's ports.
    var attached: [[UInt32]] { state.withLock { $0.attached } }

    /// One entry per `detach` call, in order, holding that call's ports.
    var detached: [[UInt32]] { state.withLock { $0.detached } }

    func attach(_ hosts: [VsockListenerHost]) async {
        state.withLock { $0.attached.append(hosts.map(\.port)) }
    }

    func detach(ports: [UInt32]) async {
        state.withLock { $0.detached.append(ports) }
    }
}
