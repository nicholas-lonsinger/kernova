import Foundation

/// Which of the library's VMs a listing answers, and in what order.
///
/// Every constraint ANDs: a VM is listed when ``filter`` admits it, it is on
/// one of ``networks`` (when any is given), and it is in every group
/// ``groups`` names. The app resolves every text; an unknown one is refused
/// rather than matching nothing.
public struct VMListQuery: Codable, Hashable, Sendable {
    /// The attributes a listed VM has.
    public var filter: VMLibraryFilter
    /// Networks as typed — a mode (``VMLibraryFilter/Network/init(spelling:)``)
    /// or a named network's name or identifier, ignoring case — which the app
    /// adds to ``filter``'s ``VMLibraryFilter/networks`` include-set.
    public var networks: [String]
    /// Groups a listed VM is in, every one of them.
    public var groups: [VMGroupReference]
    /// The order the VMs are listed in.
    public var sort: VMLibrarySort

    /// A query constraining what is given; the defaults list every VM in
    /// library order.
    public init(
        filter: VMLibraryFilter = VMLibraryFilter(), networks: [String] = [],
        groups: [VMGroupReference] = [], sort: VMLibrarySort = .manual
    ) {
        self.filter = filter
        self.networks = networks
        self.groups = groups
        self.sort = sort
    }
}

/// One group of the library's VMs, as a caller names it: by name, ignoring
/// case, or by identifier.
public struct VMGroupReference: Codable, Hashable, Sendable {
    /// What kind of group it names.
    public var kind: VMGroupKind
    /// The group's name or identifier.
    public var name: String

    /// Names the group of `kind` that `name` names.
    public init(_ kind: VMGroupKind, named name: String) {
        self.kind = kind
        self.name = name
    }
}
