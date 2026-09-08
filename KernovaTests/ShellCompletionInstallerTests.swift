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
        // The per-user folders are under the home the user sees, never the
        // sandbox container the process has.
        for shell in [ShellCompletionInstaller.Shell.bash, .fish] {
            #expect(
                shell.defaultDirectory.path(percentEncoded: false).hasPrefix(UserHome.path + "/"))
        }
    }

    @Test("zsh goes to a site-functions the user owns, or to their own home")
    func zshAvoidsAFolderTheUserCannotWrite() {
        let directory = ShellCompletionInstaller.Shell.zsh.defaultDirectory

        if let siteFunctions = ShellCompletionInstaller.siteFunctions {
            #expect(directory == siteFunctions)
            #expect(
                ShellCompletionInstaller.isUserWritableDirectory(
                    siteFunctions.path(percentEncoded: false)))
        } else {
            // Every Mac has this one, and it is the user's own.
            #expect(
                directory.path(percentEncoded: false)
                    == UserHome.path + "/.zsh/completions")
        }
    }

    @Test("A folder the user cannot create files in is not offered")
    func writabilityFollowsOwnerAndMode() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: directory)
        }
        let path = directory.path(percentEncoded: false)
        #expect(ShellCompletionInstaller.isUserWritableDirectory(path))

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        #expect(!ShellCompletionInstaller.isUserWritableDirectory(path))

        #expect(!ShellCompletionInstaller.isUserWritableDirectory(path + "/not-there"))
        // A file is not a folder to install into.
        let file = directory.appendingPathComponent("occupant")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        try Data("x".utf8).write(to: file)
        #expect(!ShellCompletionInstaller.isUserWritableDirectory(file.path(percentEncoded: false)))
    }

    @Test("The panel is pointed at the closest folder that exists")
    func theAncestorIsWhereThePanelOpens() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(ShellCompletionInstaller.existingAncestor(of: directory) == directory)
        #expect(
            ShellCompletionInstaller.existingAncestor(
                of: directory.appending(path: "one/two/three", directoryHint: .isDirectory))
                == directory)
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

        #expect(throws: InstallFailure.self) {
            try ShellCompletionInstaller.install(.zsh, at: destination)
        }
    }

    @Test("The pasteable command writes the same loader the install would")
    func theManualCommandWritesTheLoader() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for shell in ShellCompletionInstaller.Shell.allCases {
            // A folder that is not there yet, which is what the `mkdir -p` is
            // for on a Mac where none of the default ones exist.
            let folder = directory.appending(
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
