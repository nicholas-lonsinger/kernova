import ArgumentParser
import Darwin
import Foundation

/// The `kernova` tool's root command.
///
/// The whole binary is `KernovaCommand.run()`. Parsing, rendering and exit
/// codes live in this package rather than in the executable target, so all of
/// them are reachable from `KernovaKitTests` without a fourth test bundle.
public struct KernovaCommand: ParsableCommand {
    /// The tool's name, one-line abstract, and `--version` answer.
    public static let configuration = CommandConfiguration(
        commandName: "kernova",
        abstract: "Drive Kernova's virtual machines from the command line.",
        version: toolVersion,
        subcommands: [
            List.self, Info.self, IP.self,
            Start.self, Stop.self, Suspend.self, Pause.self, Resume.self, Restart.self, Open.self,
            Version.self,
        ],
        defaultSubcommand: List.self
    )

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
