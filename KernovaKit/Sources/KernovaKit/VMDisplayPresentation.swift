import Foundation

/// Whether a verb that brings a guest up puts its display in front of the user.
///
/// Carried explicitly by every wire verb that can surface one, with no default:
/// a caller with no GUI to present in — a shell over SSH, a headless
/// automation launch — must be able to say so, and a default would let it
/// surface a window nobody asked for and mark the process as having presented.
public enum VMDisplayPresentation: String, Codable, Sendable, Hashable, CaseIterable {
    /// Surface the VM's display — the detached window for a pop-out or
    /// fullscreen VM, keyboard focus in the inline display otherwise.
    case surface
    /// Bring the guest up with nothing put on screen, for a caller that has no
    /// window and is not asking for one.
    case headless
}
