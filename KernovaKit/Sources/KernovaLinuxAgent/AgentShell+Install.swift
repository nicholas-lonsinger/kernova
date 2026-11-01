#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore

extension AgentShell {
    /// Installs or uninstalls `request`'s scope from this binary, printing each step as it takes it, then
    /// exits: 0 when every step succeeded, 1 with the failure on standard error otherwise. A dry run prints
    /// the same steps, and takes none.
    static func runInstaller(_ request: AgentCommand.InstallRequest, uninstalling: Bool, label: String) -> Never {
        let scope = request.scope == .system ? "the system service" : "the session agent for this user"
        do throws(Installer.Failure) {
            if request.runsSystemd { try Installer.requireSystemd() }
            // The user manager's own environment says where it looks for units; a root shell's would not, and
            // the layout refuses root for the user scope.
            let environment =
                request.scope == .user && request.runsSystemd && geteuid() != 0
                ? try Installer.managerEnvironment() : ProcessInfo.processInfo.environment
            // A dry run changes nothing, so it needs no particular user.
            let layout = try Installer.layout(
                for: request, environment: environment,
                effectiveUID: request.scope == .system && request.dryRun ? 0 : geteuid())
            let plan: InstallPlan = uninstalling ? .uninstall(layout) : .install(layout)
            if request.dryRun {
                let verb = uninstalling ? "uninstall" : "install"
                let heading = "kernova-agent \(verb)\(request.scope == .system ? " --system" : "") will:"
                for line in InstallPlan.dryRun(plan, heading: heading) { print(line) }
                exit(0)
            }
            // A staging root is not the live tree the account owns, and the account need not exist there.
            let account = request.scope == .system && request.root == nil ? InstallLayout.systemAccount : nil
            let installer = Installer(
                stagingRoot: request.root ?? "", runsSystemd: request.runsSystemd, payloadSource: "/proc/self/exe",
                versionLabel: label, account: account)
            try installer.run(plan) { print("kernova-agent: \($0)") }
            print(uninstalling ? "kernova-agent: removed \(scope)." : "kernova-agent: installed \(scope), \(label).")
            exit(0)
        } catch {
            writeError("kernova-agent: cannot \(uninstalling ? "remove" : "install") \(scope): \(error)")
            exit(1)
        }
    }
}
#endif
