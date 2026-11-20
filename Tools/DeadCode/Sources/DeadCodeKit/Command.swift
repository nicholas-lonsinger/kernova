import Foundation

/// Why a command did not complete: its description is what the tool prints.
package struct Failure: Error, CustomStringConvertible {
    package var description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// `--name value` pairs, then whatever follows `--`; a name given more than once keeps every value.
package struct Options {
    private var values: [String: [String]] = [:]
    package private(set) var rest: [String] = []
    private let usage: String

    /// `arguments`, read for a tool whose usage, `usage`, a malformed or missing option prints.
    package init(_ arguments: ArraySlice<String>, usage: String) throws(Failure) {
        self.usage = usage
        var arguments = arguments
        while let name = arguments.popFirst() {
            if name == "--" {
                rest = Array(arguments)
                return
            }
            guard name.hasPrefix("--"), let value = arguments.popFirst() else {
                throw Failure("expected --<option> <value>, got \(name)\n\n\(usage)")
            }
            values[String(name.dropFirst(2)), default: []].append(value)
        }
    }

    package func all(_ name: String) -> [String] { values[name] ?? [] }

    package func optional(_ name: String) -> String? { values[name]?.last }

    package func required(_ name: String) throws(Failure) -> String {
        guard let value = optional(name) else { throw Failure("missing --\(name)\n\n\(usage)") }
        return value
    }
}

package func readFile(_ path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
}

package func writeFile(_ data: Data, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

/// Runs `executable` in `directory` and returns its standard output, failing when it exits non-zero.
package func runProcess(_ executable: String, _ arguments: [String], in directory: String? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw Failure("\(executable) \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
    }
    return data
}

/// Runs the command the process's first argument names, with the arguments after it, and exits: 0 once it returns, 1
/// with what it throws, or with `usage` when no command is named or the one named is not in `commands`, written to
/// standard error after `tool`'s name.
package func runCommand(
    tool: String, usage: String, _ commands: [String: (ArraySlice<String>) throws -> Void]
) -> Never {
    do {
        let arguments = CommandLine.arguments.dropFirst()
        guard let name = arguments.first else { throw Failure(usage) }
        guard let command = commands[name] else { throw Failure("unknown command \(name)\n\n\(usage)") }
        try command(arguments.dropFirst())
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(tool): \(error)\n".utf8))
        exit(1)
    }
}
