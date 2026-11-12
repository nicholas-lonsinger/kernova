import Foundation

/// How one window stands on screen.
package struct WindowStanding: Equatable {
    var isVisible: Bool
    var isMiniaturized: Bool
    var isOnActiveSpace: Bool

    package init(isVisible: Bool, isMiniaturized: Bool, isOnActiveSpace: Bool) {
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
        self.isOnActiveSpace = isOnActiveSpace
    }

    /// Whether the window is on screen, counting a miniaturized one.
    package var isPresent: Bool { isVisible || isMiniaturized }

    /// Whether the user can see the window, which is what lets it take an
    /// alert: a sheet on a miniaturized window, or on one in another Space, is
    /// on screen for nobody.
    var canTakeAlert: Bool { isVisible && !isMiniaturized && isOnActiveSpace }
}
