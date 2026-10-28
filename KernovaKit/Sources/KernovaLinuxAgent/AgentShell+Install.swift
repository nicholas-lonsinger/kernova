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

extension AgentShell {
    /// Installs or uninstalls `request`'s scope from this binary, then exits: 0 when every step succeeded,
    /// 1 with the failure on standard error otherwise.
    static func runInstaller(_ request: AgentCommand.InstallRequest, uninstalling: Bool, label: String) -> Never {
        let scope = request.scope == .system ? "the system service" : "the session agent for this user"
        do throws(Installer.Failure) {
            let layout = try Installer.layout(
                for: request, environment: ProcessInfo.processInfo.environment, effectiveUID: geteuid())
            let installer = Installer(
                stagingRoot: request.root ?? "", runsSystemd: request.runsSystemd, payloadSource: "/proc/self/exe",
                versionLabel: label)
            try installer.run(uninstalling ? .uninstall(layout) : .install(layout))
            print(uninstalling ? "kernova-agent: removed \(scope)." : "kernova-agent: installed \(scope), \(label).")
            exit(0)
        } catch {
            writeError("kernova-agent: cannot \(uninstalling ? "remove" : "install") \(scope): \(error)")
            exit(1)
        }
    }
}
#endif
