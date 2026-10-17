import Foundation

/// What alert routing reads about one window.
package struct AlertWindowState: Equatable {
    var isVisible: Bool
    var isMiniaturized: Bool
    var isOnActiveSpace: Bool

    package init(isVisible: Bool, isMiniaturized: Bool, isOnActiveSpace: Bool) {
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
        self.isOnActiveSpace = isOnActiveSpace
    }

    /// Whether the user can see the window, which is what lets it take an
    /// alert: a sheet on a miniaturized window, or on one in another Space, is
    /// on screen for nobody.
    var canTakeAlert: Bool { isVisible && !isMiniaturized && isOnActiveSpace }
}

/// The windows an alert can be shown on, as they stand at the moment one is
/// about to be — the one input ``destination(about:)`` routes from.
///
/// Generic over the window so routing is a function of values alone.
package struct AlertWindowScene<Window: Hashable> {
    /// The window the user is working in: the key window, then the main
    /// window, each answering through the window a sheet on it is attached to,
    /// with the VMs each can act on (``AppWindowRegistry/vmIDs(actedOnIn:)``).
    var working: [(window: Window, vmIDs: Set<UUID>)]
    /// Each VM's display window — one exists only while the display is popped
    /// out or full screen.
    var displayWindows: [UUID: Window]
    /// The library window, while one exists.
    var library: Window?
    /// What each window above reads as; a window missing here takes no alert.
    var states: [Window: AlertWindowState]

    package init(
        working: [(window: Window, vmIDs: Set<UUID>)], displayWindows: [UUID: Window], library: Window? = nil,
        states: [Window: AlertWindowState]
    ) {
        self.working = working
        self.displayWindows = displayWindows
        self.library = library
        self.states = states
    }

    /// The window an alert about the VM `vmID` — or about no VM, when `nil` —
    /// is shown on now, or `nil` when no window the user can see qualifies and
    /// the alert is held.
    ///
    /// An alert about a VM goes where the user is working with it: the working
    /// window when it can act on that VM, else the VM's display window, else
    /// the library window. An alert about no VM goes to the library window.
    package func destination(about vmID: UUID?) -> Window? {
        if let vmID {
            if let working = working.first(where: { $0.vmIDs.contains(vmID) && canTake($0.window) }) {
                return working.window
            }
            if let display = displayWindows[vmID], canTake(display) { return display }
        }
        guard let library, canTake(library) else { return nil }
        return library
    }

    private func canTake(_ window: Window) -> Bool {
        states[window]?.canTakeAlert ?? false
    }
}
