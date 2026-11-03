#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import KernovaAgentCore
import KernovaAgentInstall
import KernovaDBus
import KernovaPlatformLinux

/// What an install on Linux checks and reads before it has a plan: systemd running, the user manager's
/// environment, and the layout a request installs into.
enum LinuxInstall {
    /// Why an install was refused before it started.
    enum Refusal: Error, CustomStringConvertible {
        /// Nothing says where the user's files go.
        case noHome
        /// The request needs a different user than the process runs as.
        case wrongUser(String)
        /// The guest is not running systemd, which every unit the agent installs needs.
        case noSystemd

        var description: String {
            switch self {
            case .noHome: "neither XDG_DATA_HOME and XDG_CONFIG_HOME nor HOME is set to an absolute path"
            case .wrongUser(let detail): detail
            case .noSystemd: "the Kernova guest agent needs systemd, and this system is not running it"
            }
        }
    }

    /// Refuses unless the guest runs systemd: `runDirectory` exists, as sd_booted(3) tests.
    static func requireSystemd(runDirectory: String = "/run/systemd/system") throws(Refusal) {
        var info = stat()
        guard lstat(runDirectory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw .noSystemd }
    }

    /// The environment of the invoking user's systemd manager: the one it searches for units in and runs
    /// the session peer with, so the install's paths are the ones both use.
    static func managerEnvironment() throws(Installer.Failure) -> [String: String] {
        let arguments = ["systemctl", "--user", "show-environment"]
        let (status, output) = Installer.capture(arguments)
        guard status == 0 else { throw .command(arguments: arguments, status: status) }
        return InstallLayout.environment(parsingShowEnvironment: String(decoding: output, as: UTF8.self))
    }

    /// The layout `request` installs into, for a process whose environment is `environment` and whose
    /// effective uid is `effectiveUID`. User scope refuses root, whose home is not the user's; system scope
    /// needs root. A staging root waives both, since it writes no live system.
    static func layout(
        for request: AgentCommand.InstallRequest, environment: [String: String], effectiveUID: uid_t
    ) throws(Refusal) -> InstallLayout {
        let live = request.root == nil
        if request.scope == .system {
            guard !live || effectiveUID == 0 else {
                throw .wrongUser("installing the system service needs root: run it with sudo")
            }
            return .system(root: LinuxIdentity.systemInstallRoot)
        }
        guard !live || effectiveUID != 0 else {
            throw .wrongUser("run this as the user the agent is for, not as root; --system installs the system service")
        }
        guard let root = LinuxIdentity.userInstallRoot(environment: environment),
            let config = InstallLayout.configHome(environment: environment)
        else { throw .noHome }
        return .user(root: root, configHome: config)
    }

    /// An installer whose payload is this executable, the agent `label` names.
    static func installer(stagingRoot: String, runsSystemd: Bool, label: String, account: String?) -> Installer {
        Installer(
            stagingRoot: stagingRoot, runsCommands: runsSystemd, payloadSource: "/proc/self/exe",
            lander: ExecutableLander(), versionLabel: label, account: account)
    }
}

/// The systemd manager running one scope's peer, which the rollback check asks for the peer's main process.
struct SystemdServiceManager: ServiceManager {
    let scope: InstallScope

    func peerProcessID() throws -> UInt32 {
        let bus = try DBusBusConnection(bus: scope == .system ? .system : .user)
        return try SystemdManager(connection: bus).mainPID(ofService: InstallLayout.serviceName(scope))
    }
}
#endif
