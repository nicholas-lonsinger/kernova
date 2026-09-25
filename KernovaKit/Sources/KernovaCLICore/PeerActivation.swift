import AppKit
import Darwin

/// Bringing forward the app process this tool is talking to, when its answer
/// asks for it (``VMCommandResponse/Result/activate``).
enum PeerActivation {
    /// Yields activation to the process `pid`, then activates it.
    ///
    /// By pid, never by bundle identifier: several copies of Kernova can run
    /// under one bundle identifier, and only the one behind this connection is
    /// the one the request reached.
    ///
    /// Runs on the main thread, where the tool's whole run happens.
    static func activate(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        // KernovaCLICore compiles at the package floor the guest agent sets; the
        // tool itself ships at the host's deployment target, where this holds.
        guard #available(macOS 14.0, *) else { return }
        MainActor.assumeIsolated {
            NSApplication.shared.yieldActivation(to: app)
            app.activate(options: [])
        }
    }
}
