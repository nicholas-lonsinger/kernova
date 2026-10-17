import Foundation

/// What the app is presenting, read at the moment a VM comes up.
package enum GUIPosture: Equatable {
    /// Status-item-only (`.accessory`): no window may appear.
    case absent
    /// Windows exist but another app is frontmost.
    case background
    /// Kernova is the active app.
    case foreground
}

/// The decisions ``AppResidencyController`` carries out: what a launch, a
/// reopen, a window close and an unhide do with the resident app.
package enum AppResidencyPolicy {
    // MARK: - Launch

    /// What a launch asked for: who performed it, and whether it asked for the
    /// app hidden.
    package struct LaunchProvenance: Equatable {
        /// Who performed the launch.
        package enum Origin: String, Equatable {
            /// Anything a person or a launcher did — a double-click, `open`,
            /// the Dock, a Shortcut, the `kernova` tool.
            case user
            /// The system opened the app at login, on the user's standing
            /// request.
            case loginItem
        }

        let origin: Origin

        /// Whether the app came up hidden.
        ///
        /// An opener that asks for the app hidden has asked for no window. An
        /// App Intents launch is one of them: measured on macOS 27 (26A5425a)
        /// on 2026-09-04, the system brings such a launch up hidden. The
        /// `kernova` tool asks for the same thing by passing `hides`.
        let isHidden: Bool

        package init(origin: Origin, isHidden: Bool) {
            self.origin = origin
            self.isHidden = isHidden
        }
    }

    /// How a launch brings the process up, as decided by
    /// ``launchPosture(for:keepInMenuBar:)``.
    package enum LaunchPosture: Equatable {
        /// Put the library on screen. A hidden launch still creates it, behind
        /// the hide, so the Dock icon a person clicks has something to show.
        case present
        /// `.accessory`, no window.
        case headless
    }

    /// Decides what a launch puts on screen.
    ///
    /// A launch that asked for no window — hidden — and a login launch are the
    /// same request: have Kernova running, not be shown it. Both come up as the
    /// status-item app, which is the affordance that then reaches the GUI. With
    /// *Continue running in the menu bar* off there is no status item, so a
    /// headless process would be unreachable and every launch presents instead
    /// — behind the hide for a hidden one, where the Dock icon is what reaches
    /// it.
    ///
    /// Either way the auto-start pass runs, as it does on every launch, and the
    /// process stays until somebody quits it.
    package static func launchPosture(
        for provenance: LaunchProvenance, keepInMenuBar: Bool
    ) -> LaunchPosture {
        guard keepInMenuBar else { return .present }
        return provenance.origin == .loginItem || provenance.isHidden ? .headless : .present
    }

    /// Formats the resident-app startup provenance line.
    package static func residentProvenanceLine(
        bundlePath: String, build: String, configuration: String, vmNetworkingEntitled: Bool,
        launch: LaunchProvenance
    ) -> String {
        "bundle=\(bundlePath) build=\(build) config=\(configuration) "
            + "vmNetworking=\(vmNetworkingEntitled ? "entitled" : "unentitled") "
            + "launch=\(launch.origin.rawValue) hidden=\(launch.isHidden)"
    }

    // MARK: - Reopen

    /// What a reopen (a Dock click, `open`) does to the GUI, as decided by
    /// ``reopenPresentation(hasVisibleUserWindow:)``.
    package enum ReopenPresentation: Equatable {
        /// Present the library.
        case library
        /// Do nothing — a user window the app already has owns the presentation.
        case nothing
    }

    /// Decides the reopen leg's presentation: a user window the app already
    /// has owns it, so a reopen never drags the library forward over a per-VM
    /// display or clipboard window the status item opened alone — matching
    /// ``AppResidencyController/summonStatusItemTarget(for:)``'s "opens only
    /// the chosen surface" rule.
    ///
    /// A miniaturized window counts: AppKit deminiaturizes it on a reopen the
    /// delegate lets it handle.
    package static func reopenPresentation(hasVisibleUserWindow: Bool) -> ReopenPresentation {
        hasVisibleUserWindow ? .nothing : .library
    }

    // MARK: - Window Reconcile

    /// What the window reconcile does with the resident app.
    package enum ResidencyOutcome: Equatable {
        /// Show the Dock icon — a user window is on screen.
        case showDockIcon
        /// Drop to a status-item-only app; running VMs keep executing.
        case goHeadless
        /// Quit through `applicationShouldTerminate`, save-suspending running VMs.
        case quit
        /// Leave the app as it is — hidden, it is not the app's windows the
        /// reconcile would be reading.
        /// ``AppResidencyController/noteDidUnhide()`` decides once they are
        /// legible again.
        case waitForUnhide
    }

    /// Decides the reconcile's outcome.
    ///
    /// With *Continue running in the menu bar* off there is neither a Dock icon nor
    /// a status item, so a headless app would be unreachable — the last window
    /// close quits instead of demoting.
    ///
    /// Two things hold that off:
    ///
    /// - **Hiding.** ⌘H makes every window report `isVisible == false` without
    ///   closing any of them, so a hidden app's windows are open windows the
    ///   reconcile simply cannot see, and it reads the same as an app whose last
    ///   window closed. It decides nothing there — a hidden app keeps the Dock
    ///   icon a presented one had, and a background close landing mid-hide (a VM
    ///   shutting down empties its display window) is answered by
    ///   ``unhideOutcome(hasVisibleUserWindow:keepInMenuBar:)``. What *Continue
    ///   running in the menu bar* governs is the last close, not a hide.
    /// - **Work in flight.** Termination abandons the creates, clones and imports
    ///   still writing (`abandonArrivalsForTermination()`) and hard-aborts a VM that is
    ///   mid-save, mid-restore, mid-start or mid-install — `applicationShouldTerminate`
    ///   only save-suspends VMs already settled at `.running` or `.paused`. An
    ///   ordinary window close must not destroy that work, so it keeps the Dock
    ///   icon (not headless — the app has to stay reachable to show progress)
    ///   until the work settles and the observation re-runs this.
    ///
    /// A settled `.running` VM does *not* hold the quit back:
    /// `applicationShouldTerminate` save-suspends it.
    package static func residencyOutcome(
        hasVisibleUserWindow: Bool,
        isHidden: Bool,
        keepInMenuBar: Bool,
        hasUninterruptibleWork: Bool
    ) -> ResidencyOutcome {
        if hasVisibleUserWindow { return .showDockIcon }
        if isHidden { return .waitForUnhide }
        if keepInMenuBar { return .goHeadless }
        if hasUninterruptibleWork { return .showDockIcon }
        return .quit
    }

    // MARK: - Unhide

    /// What an unhide does with the resident app.
    package enum UnhideOutcome: Equatable {
        /// Show the Dock icon — windows came back with the app.
        case showDockIcon
        /// Drop to a status-item-only app: the last window closed during the
        /// hide, which is the close *Continue running in the menu bar* answers.
        case goHeadless
        /// Put the library back on screen — nothing survived the hide, and with
        /// no status item a headless app would be unreachable.
        case presentLibrary
    }

    /// Decides what the unhide does, which is never a quit.
    ///
    /// Unhiding is a request for the app, so the close that landed mid-hide is
    /// answered by making the app reachable — never by terminating under the
    /// person who just asked for it. A window close is what quits this app, and
    /// no close is observable from here: the hide swallowed whichever one
    /// happened, and AppKit's unhide restores the windows that are left.
    package static func unhideOutcome(
        hasVisibleUserWindow: Bool, keepInMenuBar: Bool
    ) -> UnhideOutcome {
        if hasVisibleUserWindow { return .showDockIcon }
        return keepInMenuBar ? .goHeadless : .presentLibrary
    }
}
