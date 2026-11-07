import DeadCodeKit
import Foundation

let usage = """
    Usage:
      dead-code test-only-targets --project <Kernova.xcodeproj>
          Prints every target of the project and of the repository's top-level packages that only tests reach.
      dead-code bundle --root <repo> --base <dir Periphery ran in> --full <json> --production <json>
                       --store <index store> --indexutil-export <path> --output <dir>
          Replaces <dir> with one platform's bundle: the two Periphery JSON reports, locations repo-relative,
          and the declaration sites and import lines the index store they read holds under <repo>.
      dead-code report --platform <name>=<dir>... [--markdown <file> --rest <text>] [--json <file>] [--summary <file>]
          Combines platform bundles (macos, linux) and prints the report.
    """

struct Failure: Error, CustomStringConvertible {
    var description: String
}

/// `--name value` pairs; a name given more than once keeps every value.
struct Options {
    private var values: [String: [String]] = [:]

    init(_ arguments: ArraySlice<String>) throws {
        var arguments = arguments
        while let name = arguments.popFirst() {
            guard name.hasPrefix("--"), let value = arguments.popFirst() else {
                throw Failure(description: "expected --<option> <value>, got \(name)\n\n\(usage)")
            }
            values[String(name.dropFirst(2)), default: []].append(value)
        }
    }

    func all(_ name: String) -> [String] { values[name] ?? [] }

    func optional(_ name: String) -> String? { values[name]?.last }

    func required(_ name: String) throws -> String {
        guard let value = optional(name) else { throw Failure(description: "missing --\(name)\n\n\(usage)") }
        return value
    }
}

func read(_ path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
}

func write(_ data: Data, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

/// Runs `executable` and returns its standard output, failing when it exits non-zero.
func run(_ executable: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw Failure(
            description: "\(executable) \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
    }
    return data
}

func testOnlyTargets(_ options: Options) throws {
    let project = URL(fileURLWithPath: try options.required("project")).standardizedFileURL
    let repository = project.deletingLastPathComponent()
    let targets = try XcodeTarget.targets(pbxproj: read(project.appendingPathComponent("project.pbxproj").path))

    let schemesDirectory = project.appendingPathComponent("xcshareddata/xcschemes")
    var schemes: [String: [String]] = [:]
    for file in try FileManager.default.contentsOfDirectory(atPath: schemesDirectory.path)
    where file.hasSuffix(".xcscheme") {
        let name = String(file.dropLast(".xcscheme".count))
        schemes[name] = try schemeLaunchTargets(
            xml: read(schemesDirectory.appendingPathComponent(file).path), scheme: name)
    }

    // A local package is a top-level directory holding a Package.swift.
    var packages: [PackageDescription] = []
    for entry in try FileManager.default.contentsOfDirectory(atPath: repository.path).sorted() {
        let directory = repository.appendingPathComponent(entry)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) else {
            continue
        }
        let json = try run(
            "/usr/bin/env", ["swift", "package", "--package-path", directory.path, "describe", "--type", "json"])
        packages.append(try JSONDecoder().decode(PackageDescription.self, from: json))
    }

    let names = try DeadCodeKit.testOnlyTargets(project: targets, packages: packages, schemes: schemes)
    print(names.joined(separator: "\n"))
}

func bundle(_ options: Options) throws {
    let root = try options.required("root")
    let base = try options.required("base")
    func view(_ name: String) throws -> [Finding] {
        try JSONDecoder().decode([Finding].self, from: read(try options.required(name)))
            .map { try $0.normalized(root: root, base: base) }
    }
    let bundle = PlatformBundle(
        full: try view("full"), production: try view("production"),
        presence: try presence(
            exporter: try options.required("indexutil-export"), store: try options.required("store"), root: root))
    try bundle.write(to: URL(fileURLWithPath: try options.required("output")))
}

/// What `store` holds under `root`.
///
/// `indexutil-export tsv <store> <dir>` writes three files into `<dir>`; only the occurrences are read, streamed
/// from its standard output through a symlink, and the other two go to `/dev/null`.
func presence(exporter: String, store: String, root: String) throws -> Presence {
    var filter = PresenceFilter(root: root)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dead-code-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for (file, destination) in [
        ("symbols.tsv", "/dev/null"), ("relations.tsv", "/dev/null"), ("occurrences.tsv", "/dev/stdout"),
    ] {
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent(file).path, withDestinationPath: destination)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: exporter)
    process.arguments = ["tsv", store, directory.path]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let reader = output.fileHandleForReading
    while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
        filter.consume(chunk)
    }
    filter.finish()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw Failure(description: "\(exporter) exited \(process.terminationStatus) exporting \(store)")
    }
    guard !filter.presence.keys.isEmpty else {
        throw Failure(description: "\(store) holds no declaration under \(root)")
    }
    return filter.presence
}

func report(_ options: Options) throws {
    var full: [PlatformScan] = []
    var production: [PlatformScan] = []
    for spec in options.all("platform") {
        let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, let platform = Platform(rawValue: parts[0]) else {
            let names = Platform.allCases.map(\.rawValue).joined(separator: ", ")
            throw Failure(description: "--platform takes <name>=<dir>, the name one of \(names): \(spec)")
        }
        let bundle = try PlatformBundle(contentsOf: URL(fileURLWithPath: parts[1]))
        full.append(PlatformScan(platform: platform, findings: bundle.full, presence: bundle.presence))
        production.append(PlatformScan(platform: platform, findings: bundle.production, presence: bundle.presence))
    }
    guard !full.isEmpty else { throw Failure(description: "no --platform given\n\n\(usage)") }

    let report = try DeadCodeReport(full: full, production: production)
    print(report.text, terminator: "")
    if let path = options.optional("markdown") {
        let rest = try options.required("rest")
        try write(Data(report.markdown(limit: 60_000, rest: rest).utf8), to: path)
    }
    if let path = options.optional("json") { try write(report.json(), to: path) }
    // Appended, as a GitHub Actions step's output file takes it.
    if let path = options.optional("summary") {
        guard let stream = OutputStream(toFileAtPath: path, append: true) else {
            throw Failure(description: "cannot open \(path)")
        }
        stream.open()
        defer { stream.close() }
        let bytes = Array(report.summary.utf8)
        guard stream.write(bytes, maxLength: bytes.count) == bytes.count else {
            throw Failure(description: "cannot write \(path)")
        }
    }
}

do {
    let arguments = CommandLine.arguments.dropFirst()
    guard let command = arguments.first else { throw Failure(description: usage) }
    let options = try Options(arguments.dropFirst())
    switch command {
    case "test-only-targets": try testOnlyTargets(options)
    case "bundle": try bundle(options)
    case "report": try report(options)
    default: throw Failure(description: "unknown command \(command)\n\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("dead-code: \(error)\n".utf8))
    exit(1)
}
