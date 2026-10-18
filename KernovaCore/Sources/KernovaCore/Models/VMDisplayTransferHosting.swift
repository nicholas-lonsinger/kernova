import Foundation

/// What a VM display moves files through, both ways: drops sent into the guest,
/// and the guest's own drags taken over at the display's edge.
///
/// The display resolves its host once per question rather than holding one, and
/// observes ``displayDropAvailability`` itself — reading it registers
/// everything it depends on — so a window or pane hosting a display wires one
/// closure and nothing else.
@MainActor
package protocol VMDisplayTransferHosting: AnyObject {
    /// The VM's identity, so its display can tell a drag that came out of it.
    var id: UUID { get }

    /// Whether files dragged onto the display can be sent to the guest.
    var displayDropAvailability: DisplayDropAvailability { get }

    /// Sends dropped `urls` to the guest, reporting whether the drop was taken;
    /// `stagedIn` is the directory a promise drag wrote them into.
    func sendDroppedFilesToGuest(_ urls: [URL], stagedIn stagingDirectory: URL?) -> Bool

    /// Reports a drag the display took that produced no file to send.
    func reportUnreadableDropToGuest()

    /// Records that a press began on the display.
    func displayPressBegan()

    /// Takes over the drag the guest is offering for `display`, or returns
    /// `nil` when there is none it can take.
    func takeGuestDrag(display: any GuestDragDisplay) -> (any GuestDragTaking)?
}

extension VMInstance: VMDisplayTransferHosting {}
