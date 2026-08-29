import Foundation

/// One change to the VM library, for a caller that cannot observe the model.
///
/// The `@Observable` UI reads the model directly; this stream exists for
/// everything else — a CLI waiting on a state, an App Intent reporting
/// completion. Intermediate states may be coalesced: the stream reports what a
/// VM reached, not every value it passed through.
///
/// Every case is backed by observable model state, which is what lets the
/// stream wake on its own. A guest's reserved address is not: it lives in the
/// vmnet layer, which publishes nothing, so it is absent here rather than
/// present as a case that only fires when something else happens to change.
public enum VMLibraryEvent: Codable, Sendable, Hashable {
    /// A VM entered the library — created, cloned, imported, or found on disk.
    case added(VMSummary)
    /// A VM left the library.
    case removed(id: UUID, name: String)
    /// A VM's runtime status settled at a new value.
    case statusChanged(id: UUID, name: String, from: String, to: String)
    /// A VM's guest-agent connectivity changed.
    case agentStatusChanged(id: UUID, name: String, status: String)
    /// A VM entered its error state, carrying whatever it reported.
    case failure(id: UUID, name: String, message: String)
}
