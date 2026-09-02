import Foundation

@testable import Kernova

/// A plain instance list in place of ``VMLibrary``, so a collaborator that only
/// reads the roster can be driven without one.
@MainActor
final class StubVMInstanceRoster: VMInstanceRoster {
    var instances: [VMInstance]

    init(_ instances: [VMInstance] = []) {
        self.instances = instances
    }
}
