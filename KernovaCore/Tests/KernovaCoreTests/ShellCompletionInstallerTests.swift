import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Writing the file a shell loads the `kernova` tool's completions from.
@Suite("Shell completion installer", .caseScoped)
struct ShellCompletionInstallerTests {
    private let scratch = TestScratchDirectory(prefix: "knv-comp")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
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
        // The per-user folders are under the home the user sees, never the
        // sandbox container the process has.
        for shell in [ShellCompletionInstaller.Shell.bash, .fish] {
            #expect(
                shell.defaultDirectory.path(percentEncoded: false).hasPrefix(UserHome.path + "/"))
        }
    }

    @Test("zsh goes to the first site-functions the user can write into")
    func zshTakesTheFirstWritableSiteFunctions() throws {
        let missing = scratch.url.appending(path: "missing").standardizedFileURL.path
        let readOnly = try makeFolder("read-only", permissions: 0o555)
        let preferred = try makeFolder("preferred", permissions: 0o755)
        let later = try makeFolder("later", permissions: 0o755)

        let directory = ShellCompletionInstaller.zshDirectory(
            siteFunctionsCandidates: [missing, readOnly, preferred, later])

        #expect(directory.standardizedFileURL.path == preferred)
    }

    @Test("zsh goes to the user's own folder when no site-functions is theirs")
    func zshFallsBackToTheUsersHome() throws {
        let missing = scratch.url.appending(path: "missing").standardizedFileURL.path
        let readOnly = try makeFolder("read-only", permissions: 0o555)

        let directory = ShellCompletionInstaller.zshDirectory(
            siteFunctionsCandidates: [missing, readOnly])

        #expect(
            directory.standardizedFileURL.path
                == URL(fileURLWithPath: UserHome.path + "/.zsh/completions").standardizedFileURL
                .path)
    }

    /// A new folder in the scratch directory with `permissions`, as its path.
    private func makeFolder(_ name: String, permissions: Int) throws -> String {
        let path = scratch.url.appending(path: name).standardizedFileURL.path
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: false,
            attributes: [.posixPermissions: permissions])
        return path
    }

    @Test("A folder the user cannot create files in is not offered")
    func writabilityFollowsOwnerAndMode() throws {
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scratch.url.path(percentEncoded: false))
        }
        let path = scratch.url.path(percentEncoded: false)
        #expect(ShellCompletionInstaller.isUserWritableDirectory(path))

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        #expect(!ShellCompletionInstaller.isUserWritableDirectory(path))

        #expect(!ShellCompletionInstaller.isUserWritableDirectory(path + "/not-there"))
        // A file is not a folder to install into.
        let file = scratch.url.appendingPathComponent("occupant")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        try Data("x".utf8).write(to: file)
        #expect(!ShellCompletionInstaller.isUserWritableDirectory(file.path(percentEncoded: false)))
    }

    @Test("The panel is pointed at the closest folder that exists")
    func theAncestorIsWhereThePanelOpens() throws {
        #expect(ShellCompletionInstaller.existingAncestor(of: scratch.url) == scratch.url)
        #expect(
            ShellCompletionInstaller.existingAncestor(
                of: scratch.url.appending(path: "one/two/three", directoryHint: .isDirectory))
                == scratch.url)
        #expect(
            ShellCompletionInstaller.existingAncestor(
                of: URL(fileURLWithPath: "/nowhere/at/all", isDirectory: true))
                == URL(fileURLWithPath: "/", isDirectory: true))
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
        let zsh = ShellCompletionInstaller.Shell.zsh.loaderScript
        #expect(zsh.contains("_kernova \"$@\""))
        #expect(zsh.hasPrefix("#compdef kernova\n"))
        // The re-entry guard unwinds with the function rather than being
        // cleared by a line that an interrupt could skip.
        #expect(zsh.contains("local _kernova_loading=1"))
        #expect(!zsh.contains("unset"))
    }

    @Test("Reinstalling replaces what an earlier install left")
    func installReplacesAnOlderLoader() throws {
        let destination = scratch.url.appendingPathComponent("kernova")
        try Data("stale".utf8).write(to: destination)

        try ShellCompletionInstaller.install(.bash, at: destination)

        let written = try String(contentsOf: destination, encoding: .utf8)
        #expect(written == ShellCompletionInstaller.Shell.bash.loaderScript)
    }

    @Test("The pasteable command writes the same loader the install would")
    func theManualCommandWritesTheLoader() throws {
        for shell in ShellCompletionInstaller.Shell.allCases {
            // A folder that is not there yet, which is what the `mkdir -p` is
            // for on a Mac where none of the default ones exist.
            let folder = scratch.url.appending(
                path: shell.rawValue, directoryHint: .isDirectory)
            let destination = folder.appending(path: shell.fileName)
            let command = ShellCompletionInstaller.manualCommand(for: shell, at: destination)

            // One line, so it can be selected out of a callout and pasted.
            #expect(!command.contains("\n"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)

            let written = try String(contentsOf: destination, encoding: .utf8)
            #expect(written == shell.loaderScript)
        }
    }
}
