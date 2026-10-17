import Foundation

/// The decisions ``VMDisplayPlacementController`` carries out: where each
/// transition leaves a VM's display, what Pop Out does, how a bring-up readies
/// a display window, how a pop-in restores the library, and which screen
/// fullscreen opens on.
package enum VMDisplayPlacement {
    /// Why a display window is closing.
    package enum CloseReason: Equatable {
        /// The user closed the window (red button / ⌘W): the VM keeps running
        /// headless — nothing pops back into the main window.
        case userClose
        /// App-initiated dismissal — the VM stopped/errored/suspended out
        /// from under the window, or the whole GUI is being dismissed.
        case appDismissal
        /// Explicit Pop In: the display returns to the main window's detail
        /// pane and `displayPreference` reverts to `.inline`.
        case popIn
    }

    /// A change in where a VM's display lives.
    package enum DisplayTransition: Equatable {
        /// A display window was put on screen, in the style the request asked for.
        case shown(fullscreen: Bool)
        case enteredFullscreen
        case exitedFullscreen
        case closed(CloseReason)
    }

    /// The app-level work a transition owes once the window list has settled.
    package enum FollowUp: Equatable {
        case none
        /// Bring the library back so the popped-in display is visible.
        case restoreLibrary
    }

    /// Where a transition leaves the VM's display.
    package struct Placement: Equatable {
        /// The runtime hosting the VM lands in.
        package let mode: VMDisplayMode
        /// The preference to persist, or `nil` to leave the persisted one alone.
        package let persistPreference: VMDisplayPreference?
        package let followUp: FollowUp
    }

    /// What "Pop Out Display" does, given the VM's current placement.
    package enum PopOutAction: Equatable {
        /// A window is open: close it, which pops the display back in.
        case closeWindowForPopIn
        /// The VM runs headless with no window: return the display slot directly.
        case popInFromHeadless
        /// The display is inline: detach it into a window.
        case popOut
    }

    /// How a display window goes on screen.
    package enum WindowShow: Equatable {
        /// Key and frontmost, in fullscreen when asked for it.
        case front(fullscreen: Bool)
        /// Ordered into Kernova's own window layer, taking neither key nor the
        /// screen from the app the user is in.
        case behind
    }

    /// How a pop-in restores the library window.
    package enum LibraryRestore: Equatable {
        /// The user popped in from the display window — focus the library.
        case focusLibrary
        /// The pop-in happened while Kernova was not active — show the library
        /// without stealing focus from the app the user is in.
        case showInBackground
        /// The user is already in another Kernova window.
        case none
    }

    /// Decides what "Pop Out Display" does for a VM.
    package static func popOutAction(hasWindow: Bool, mode: VMDisplayMode) -> PopOutAction {
        if hasWindow { return .closeWindowForPopIn }
        return mode == .hidden ? .popInFromHeadless : .popOut
    }

    /// Decides where a transition leaves the display, and what the app owes
    /// afterwards.
    ///
    /// A `nil` `persistPreference` leaves the persisted value alone: the open
    /// path persisted the user's choice at the request site, and a close that
    /// is not a pop-in must keep the style the next reopen restores.
    package static func placement(for transition: DisplayTransition) -> Placement {
        switch transition {
        case .shown(let fullscreen):
            Placement(
                mode: fullscreen ? .fullscreen : .popOut, persistPreference: nil, followUp: .none)
        case .enteredFullscreen:
            Placement(mode: .fullscreen, persistPreference: .fullscreen, followUp: .none)
        case .exitedFullscreen:
            Placement(mode: .popOut, persistPreference: .popOut, followUp: .none)
        case .closed(.userClose):
            Placement(mode: .hidden, persistPreference: nil, followUp: .none)
        case .closed(.appDismissal):
            Placement(mode: .inline, persistPreference: nil, followUp: .none)
        case .closed(.popIn):
            Placement(mode: .inline, persistPreference: .inline, followUp: .restoreLibrary)
        }
    }

    /// How a bring-up readies this VM's display, or `nil` when it readies
    /// nothing.
    ///
    /// Two VMs get nothing. An inline one shows in whichever row is selected,
    /// and a bring-up does not change the user's selection. And an app that is
    /// presenting no GUI was asked not to have one — a window here would hand
    /// it the Dock icon and menu bar it came up without.
    ///
    /// A bring-up is not a request to look at the guest, so the window takes
    /// key and the screen only where the user is already in Kernova and asked
    /// for this VM. From another app, or for a VM nobody asked for in
    /// particular, it goes up behind what they are looking at — which is also
    /// why fullscreen is reserved for that one case: entering it moves the user
    /// to a Space they did not ask for.
    package static func readying(
        preference: VMDisplayPreference, posture: GUIPosture, presence: VMBringUpPresence
    ) -> WindowShow? {
        guard preference != .inline else { return nil }
        switch (posture, presence) {
        case (.absent, _): return nil
        case (.background, _), (.foreground, .unattended): return .behind
        case (.foreground, .attended): return .front(fullscreen: preference == .fullscreen)
        }
    }

    /// Decides how a pop-in brings the library back.
    package static func libraryRestore(
        wasKeyWindow: Bool, appWasActive: Bool
    ) -> LibraryRestore {
        if wasKeyWindow && appWasActive { return .focusLibrary }
        if !appWasActive { return .showInBackground }
        return .none
    }

    /// The screen a VM enters fullscreen on: the display it was last
    /// fullscreen on while that display is connected, else the library
    /// window's screen, else the first of `screens`.
    package static func fullscreenScreen<Screen>(
        lastDisplayID: UInt32?, screens: [Screen], libraryScreen: Screen?,
        displayID: (Screen) -> UInt32?
    ) -> Screen? {
        if let lastDisplayID, let last = screens.first(where: { displayID($0) == lastDisplayID }) {
            return last
        }
        return libraryScreen ?? screens.first
    }
}
