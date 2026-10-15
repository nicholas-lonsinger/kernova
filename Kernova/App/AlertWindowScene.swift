import AppKit

/// What alert routing reads about one window.
struct AlertWindowState: Equatable {
    var isVisible: Bool
    var isMiniaturized: Bool
    var isOnActiveSpace: Bool

    /// Whether the user can see the window, which is what lets it take an
    /// alert: a sheet on a miniaturized window, or on one in another Space, is
    /// on screen for nobody.
    var canTakeAlert: Bool { isVisible && !isMiniaturized && isOnActiveSpace }
}

extension AlertWindowState {
    @MainActor
    init(_ window: NSWindow) {
        self.init(
            isVisible: window.isVisible, isMiniaturized: window.isMiniaturized,
            isOnActiveSpace: window.isOnActiveSpace)
    }
}

/// The windows an alert can be shown on, as they stand at the moment one is
/// about to be — the one input ``destination(about:)`` routes from.
///
/// Generic over the window so routing is a function of values alone.
struct AlertWindowScene<Window: Hashable> {
    /// The window the user is working in: the key window, then the main
    /// window, each answering through the window a sheet on it is attached to,
    /// with the VM each shows (``AppWindowRegistry/instance(shownIn:)``).
    var working: [(window: Window, vmID: UUID?)]
    /// Each VM's display window — one exists only while the display is popped
    /// out or full screen.
    var displayWindows: [UUID: Window]
    /// The library window, while one exists.
    var library: Window?
    /// What each window above reads as; a window missing here takes no alert.
    var states: [Window: AlertWindowState]

    /// The window an alert about the VM `vmID` — or about no VM, when `nil` —
    /// is shown on now, or `nil` when no window the user can see qualifies and
    /// the alert is held.
    ///
    /// An alert about a VM goes where the user is working with it: the working
    /// window when it shows that VM, else the VM's display window, else the
    /// library window. An alert about no VM goes to the library window.
    func destination(about vmID: UUID?) -> Window? {
        if let vmID {
            if let working = working.first(where: { $0.vmID == vmID && canTake($0.window) }) {
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
