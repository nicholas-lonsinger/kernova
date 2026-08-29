import Foundation

/// One change to the VM library, for a caller that cannot observe the model.
///
/// The `@Observable` UI reads the model directly; this stream exists for a wire
/// client, which waits on a state it cannot watch. Intermediate states may be
/// coalesced: the stream reports what a VM reached, not every value it passed
/// through.
///
/// A case exists when its subject has a definite moment and an owner that
/// knows it: the model diff below for anything the model keeps, the failing
/// site itself for a message no surviving field can hold — a clone or import
/// copy that fails evicts its phantom row in the same turn that would have
/// reported it, so the diff can only ever see it vanish. A guest's reserved
/// address has neither: it lives in the vmnet layer, which publishes nothing
/// and names no failing site of its own, so it is absent here rather than
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
    /// A VM entered its error state, or a clone/import copying it in failed —
    /// either way, carrying whatever message it reported.
    case failure(id: UUID, name: String, message: String)
    /// A VM's display name changed.
    case renamed(id: UUID, from: String, to: String)
}
