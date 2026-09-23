import ArgumentParser
import Darwin
import Foundation

/// The `kernova` tool's root command.
///
/// The shipped tool runs in the App Sandbox, which fails `tcsetattr` on a
/// terminal with `EPERM` (kernel: `deny(1) file-ioctl path:/dev/tty
/// ioctl-command:(_IO "t" 22)`, observed 2026-09-22 on macOS 27.0), and
/// `readpassphrase(3)` ignores the failure and reads with echo on — so a
/// terminal prompt that hides its input unsandboxed echoes the secret in the
/// shipped tool. A secret reaches this tool on standard input, or the app asks
/// for it.
public struct KernovaCommand: ParsableCommand {
    /// The tool's name, one-line abstract, and `--version` answer.
    public static let configuration = CommandConfiguration(
        commandName: "kernova",
        abstract: "Drive Kernova's virtual machines from the command line.",
        discussion: launchNote + "\n\n" + CLIExitCode.contract,
        version: toolVersion,
        subcommands: [
            List.self, Info.self, IP.self,
            Start.self, Stop.self, Suspend.self, Pause.self, Resume.self, Restart.self, Open.self,
            Wait.self,
            Snapshot.self,
            Get.self, Set.self, Share.self, USB.self,
            Clone.self, Import.self, Rename.self, Delete.self, Reveal.self,
            Quit.self,
            Version.self,
        ],
        defaultSubcommand: List.self
    )

    /// What every verb does about an app that is not there, printed above the
    /// exit codes.
    private static let launchNote =
        "A verb starts Kernova, hidden and unfocused, when it is not running; `--no-launch` "
        + "refuses instead. `kernova quit` never starts it."

    /// What `kernova --version` prints.
    ///
    /// The app and the tool it embeds ship as one thing, so this is the app's
    /// marketing version, read from the tool's own embedded `Info.plist`.
    static var toolVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    /// Creates the root command; ArgumentParser fills in the rest.
    public init() {}

    /// Runs the tool and exits; never returns.
    ///
    /// Parse-and-map by hand rather than through `ParsableCommand.main()`, so
    /// ArgumentParser's `EX_USAGE` (64) never escapes as a code a caller would
    /// have to know about — every exit is one of ``CLIExitCode``.
    public static func run() -> Never {
        do {
            var command = try parseAsRoot()
            try command.run()
        } catch let failure as CLIFailure {
            write(failure.message, to: FileHandle.standardError)
            Darwin.exit(failure.code.rawValue)
        } catch {
            // `--help` and `--version` arrive here as clean exits: their output
            // is the answer, so it goes to stdout and the process succeeds.
            let isCleanExit = exitCode(for: error) == .success
            write(
                fullMessage(for: error),
                to: isCleanExit ? FileHandle.standardOutput : FileHandle.standardError)
            Darwin.exit(isCleanExit ? CLIExitCode.success.rawValue : CLIExitCode.usage.rawValue)
        }
        Darwin.exit(CLIExitCode.success.rawValue)
    }

    private static func write(_ text: String, to handle: FileHandle) {
        guard !text.isEmpty else { return }
        handle.write(Data((text + "\n").utf8))
    }
}
