import Cocoa
import KernovaAppRegistry

/// What ``AppTerminationController`` reads from and asks of AppKit: the quit
/// Apple Event being handled, the running application that sent it, and the
/// termination a finished save pass ends.
extension AppTerminationController {
    /// A controller wired to the process's own Apple Event manager, running
    /// applications and `NSApp`.
    convenience init(viewModel: VMLibraryViewModel, residency: any SoftQuitHosting) {
        self.init(
            viewModel: viewModel, residency: residency, pendingQuitEvent: Self.currentQuitEvent,
            senderProbe: .runningProcesses, endTermination: Self.end)
    }

    /// Whether `event` is the Standard Suite's quit.
    nonisolated static func isQuitEvent(_ event: NSAppleEventDescriptor) -> Bool {
        event.eventClass == AEEventClass(kCoreEventClass)
            && event.eventID == AEEventID(kAEQuitApplication)
    }

    /// The quit Apple Event `NSAppleEventManager` is handling, if the event it
    /// is handling is the Standard Suite's quit.
    ///
    /// A sender PID is stamped on an event as it is received, never on one
    /// built locally.
    static func currentQuitEvent() -> QuitEvent? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, isQuitEvent(event)
        else { return nil }
        return QuitEvent(senderPID: event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value)
    }

    /// Ends a termination the way `ending` names, through AppKit.
    static func end(_ ending: TerminationEnding) {
        switch ending {
        case .deferredReply:
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        case .terminate:
            NSApp.terminate(nil)
        }
    }
}

extension AppTerminationController.QuitSenderProbe {
    /// The processes running on this Mac.
    ///
    /// Two probes, not one: `NSRunningApplication` alone reads a live non-GUI
    /// sender like `osascript` as dead, and the Dock's stay-resident outcome
    /// depends on being seen as alive *and* identifiable.
    static var runningProcesses: Self {
        Self(
            isProcessAlive: processIsRunning,
            bundleID: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier })
    }
}

extension NSApplication.TerminateReply {
    init(_ reply: AppTerminationController.TerminationReply) {
        switch reply {
        case .cancel: self = .terminateCancel
        case .now: self = .terminateNow
        case .later: self = .terminateLater
        }
    }
}
