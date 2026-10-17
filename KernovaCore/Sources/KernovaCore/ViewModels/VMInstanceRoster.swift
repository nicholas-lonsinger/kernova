import Foundation

/// Read access to the set of VMs the app knows about, for the collaborators
/// ``VMLibrary`` sequences without handing them ownership of the list.
///
/// Conformers are `@Observable`, so a read reaches the observation tracking a
/// SwiftUI or AppKit surface installed — a collaborator that cached the array
/// would silently drop that dependency.
@MainActor
protocol VMInstanceRoster: AnyObject {
    var instances: [VMInstance] { get }
}
