import Foundation
import Testing

@testable import Kernova

/// Writing the file a shell loads the `kernova` tool's completions from.
@Suite("Shell completion installer", .admissionGated)
struct ShellCompletionInstallerTests {
    /// A fresh directory the test owns, removed when it ends.
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("knv-comp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Every shell has a file name it looks for and a folder it looks in")
    func eachShellNamesItsOwnFile() {
        #expect(ShellCompletionInstaller.Shell.zsh.fileName == "_kernova")
        #expect(ShellCompletionInstaller.Shell.bash.fileName == "kernova")
        #expect(ShellCompletionInstaller.Shell.fish.fileName == "kernova.fish")

        for shell in ShellCompletionInstaller.Shell.allCases {
            let directory = shell.defaultDirectory.path(percentEncoded: false)
            #expect(directory.hasPrefix("/"))
            #expect(directory.contains(shell.rawValue))
        }
        // The two per-user folders are under the home the user sees, never the
        // sandbox container the process has.
        for shell in [ShellCompletionInstaller.Shell.bash, .fish] {
            #expect(
                shell.defaultDirectory.path(percentEncoded: false).hasPrefix(UserHome.path + "/"))
        }
    }

    @Test("Each loader asks its own shell for the script, and names the tool")
    func eachLoaderLoadsFromTheTool() {
        for shell in ShellCompletionInstaller.Shell.allCases {
            let script = shell.loaderScript
            #expect(script.contains("kernova --generate-completion-script \(shell.rawValue)"))
            // Nothing runs when no tool is on the PATH: a shell whose startup a
            // removed tool breaks would be worse than no completions.
            #expect(script.contains("kernova"))
            #expect(script.hasSuffix("\n"))
        }
        // zsh's loader calls the function itself; the generated script's own
        // self-call never fires from inside an `eval`.
        #expect(ShellCompletionInstaller.Shell.zsh.loaderScript.contains("_kernova \"$@\""))
        #expect(ShellCompletionInstaller.Shell.zsh.loaderScript.hasPrefix("#compdef kernova\n"))
    }

    @Test("Installing writes the loader where it was asked to")
    func installWritesTheLoader() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("_kernova")

        try ShellCompletionInstaller.install(.zsh, at: destination)

        let written = try String(contentsOf: destination, encoding: .utf8)
        #expect(written == ShellCompletionInstaller.Shell.zsh.loaderScript)
    }

    @Test("Reinstalling replaces what an earlier install left")
    func installReplacesAnOlderLoader() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("kernova")
        try Data("stale".utf8).write(to: destination)

        try ShellCompletionInstaller.install(.bash, at: destination)

        let written = try String(contentsOf: destination, encoding: .utf8)
        #expect(written == ShellCompletionInstaller.Shell.bash.loaderScript)
    }

    @Test("A destination nothing can be written to is refused, not ignored")
    func anUnwritableDestinationIsRefused() {
        let destination = URL(fileURLWithPath: "/no-such-folder/_kernova")

        #expect(throws: ShellCompletionInstaller.InstallFailure.self) {
            try ShellCompletionInstaller.install(.zsh, at: destination)
        }
    }

    @Test("The pasteable command writes the same loader to the same place")
    func theManualCommandWritesTheLoader() {
        let destination = URL(fileURLWithPath: "/usr/local/share/zsh/site-functions/_kernova")

        let command = ShellCompletionInstaller.manualCommand(for: .zsh, at: destination)

        // One line, so it can be selected out of a callout and pasted.
        #expect(!command.contains("\n"))
        #expect(command.contains("mkdir -p '/usr/local/share/zsh/site-functions'"))
        #expect(command.hasSuffix("> '/usr/local/share/zsh/site-functions/_kernova'"))
        for line in ShellCompletionInstaller.Shell.zsh.loaderScript
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        {
            #expect(command.contains("'\(line)'"))
        }
    }
}
