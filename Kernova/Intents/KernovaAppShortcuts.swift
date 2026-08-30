import AppIntents
import Foundation

/// The verbs Siri answers with no user setup.
///
/// Deliberately the four a person says out loud; everything else is reachable
/// as a Shortcuts action. Each phrase names a VM, so the entity query's
/// vocabulary has to follow the library —
/// ``VMIntentGateway`` refreshes it whenever a VM is added, removed, or renamed.
struct KernovaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVMIntent(),
            phrases: [
                "Start \(\.$vm) in \(.applicationName)",
                "Boot \(\.$vm) in \(.applicationName)",
            ],
            shortTitle: "Start Virtual Machine",
            systemImageName: "play.fill")
        AppShortcut(
            intent: StopVMIntent(),
            phrases: [
                "Stop \(\.$vm) in \(.applicationName)",
                "Shut down \(\.$vm) in \(.applicationName)",
            ],
            shortTitle: "Stop Virtual Machine",
            systemImageName: "stop.fill")
        AppShortcut(
            intent: SuspendVMIntent(),
            phrases: [
                "Suspend \(\.$vm) in \(.applicationName)"
            ],
            shortTitle: "Suspend Virtual Machine",
            systemImageName: "pause.circle")
        AppShortcut(
            intent: OpenVMIntent(),
            phrases: [
                "Open \(\.$vm) in \(.applicationName)",
                "Show \(\.$vm) in \(.applicationName)",
            ],
            shortTitle: "Open Virtual Machine",
            systemImageName: "macwindow")
    }
}
