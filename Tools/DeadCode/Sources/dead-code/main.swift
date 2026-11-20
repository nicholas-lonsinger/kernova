import DeadCodeKit
import Foundation

let usage = """
    Usage:
      dead-code test-only-targets --project <Kernova.xcodeproj>
          Prints every target of the project and of the repository's top-level packages that only tests reach.
      dead-code report --platform <name>=<dir>... [--remedy <text>] [--markdown <file> --rest <text>]
                       [--json <file>] [--summary <file>]
          Combines platform bundles (macos, linux), as dead-code-sources bundle writes them, and prints the report; a
          partial one opens with <text>.
    """

func testOnlyTargets(_ options: Options) throws {
    let project = URL(fileURLWithPath: try options.required("project")).standardizedFileURL
    let repository = project.deletingLastPathComponent()
    let targets = try XcodeTarget.targets(pbxproj: readFile(project.appendingPathComponent("project.pbxproj").path))

    let schemesDirectory = project.appendingPathComponent("xcshareddata/xcschemes")
    var schemes: [String: [String]] = [:]
    for file in try FileManager.default.contentsOfDirectory(atPath: schemesDirectory.path)
    where file.hasSuffix(".xcscheme") {
        let name = String(file.dropLast(".xcscheme".count))
        schemes[name] = try schemeLaunchTargets(
            xml: readFile(schemesDirectory.appendingPathComponent(file).path), scheme: name)
    }

    // A local package is a top-level directory holding a Package.swift.
    var packages: [PackageDescription] = []
    for entry in try FileManager.default.contentsOfDirectory(atPath: repository.path).sorted() {
        let directory = repository.appendingPathComponent(entry)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) else {
            continue
        }
        let json = try runProcess(
            "/usr/bin/env", ["swift", "package", "--package-path", directory.path, "describe", "--type", "json"])
        packages.append(try JSONDecoder().decode(PackageDescription.self, from: json))
    }

    let names = try DeadCodeKit.testOnlyTargets(project: targets, packages: packages, schemes: schemes)
    print(names.joined(separator: "\n"))
}

func report(_ options: Options) throws {
    var bundles: [(platform: Platform, bundle: PlatformBundle)] = []
    for spec in options.all("platform") {
        let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, let platform = Platform(rawValue: parts[0]) else {
            let names = Platform.allCases.map(\.rawValue).joined(separator: ", ")
            throw Failure("--platform takes <name>=<dir>, the name one of \(names): \(spec)")
        }
        bundles.append((platform, try PlatformBundle(contentsOf: URL(fileURLWithPath: parts[1]))))
    }
    guard !bundles.isEmpty else { throw Failure("no --platform given\n\n\(usage)") }

    let report = try DeadCodeReport(bundles: bundles)
    print(report.text(remedy: options.optional("remedy")), terminator: "")
    if let path = options.optional("markdown") {
        let rest = try options.required("rest")
        try writeFile(Data(report.markdown(limit: 60_000, rest: rest).utf8), to: path)
    }
    if let path = options.optional("json") { try writeFile(report.json(), to: path) }
    // Appended, as a GitHub Actions step's output file takes it.
    if let path = options.optional("summary") {
        guard let stream = OutputStream(toFileAtPath: path, append: true) else {
            throw Failure("cannot open \(path)")
        }
        stream.open()
        defer { stream.close() }
        let bytes = Array(report.summary.utf8)
        guard stream.write(bytes, maxLength: bytes.count) == bytes.count else {
            throw Failure("cannot write \(path)")
        }
    }
}

runCommand(
    tool: "dead-code", usage: usage,
    [
        "test-only-targets": { try testOnlyTargets(Options($0, usage: usage)) },
        "report": { try report(Options($0, usage: usage)) },
    ])
