import DeadCodeKit
import DeadCodeSources
import Foundation

let usage = """
    Usage:
      dead-code-sources bundle --root <repo> --base <dir Periphery runs in> --periphery <path> --store <index store>
                               --indexutil-export <path> --test-only-targets <file> [--package-description <json>]
                               --output <dir> [-- <what Periphery scans>...]
          Scans <store> with Periphery, the full view and the production view without the targets <file> lists,
          and replaces <dir> with one platform's bundle: the two reports, locations repo-relative and the
          production one less what only a Debug build compiles of the sources under <repo>, and the declaration
          sites and import lines the store holds under <repo>. With a package's description, as
          `swift package describe --type json` writes it, every Swift target it declares must be in the store.
    """

func bundle(_ options: Options) throws {
    let root = URL(fileURLWithPath: try options.required("root")).standardizedFileURL.path
    let base = URL(fileURLWithPath: try options.required("base")).standardizedFileURL.path
    let store = try options.required("store")
    let description = options.optional("package-description")
    let testOnly = String(decoding: try readFile(try options.required("test-only-targets")), as: UTF8.self)
        .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let scan = try PeripheryScan(
        configuration: root + "/.periphery.yml", store: store, packageDescription: description,
        arguments: options.rest, testOnlyTargets: testOnly)

    let presence = try presence(exporter: try options.required("indexutil-export"), store: store, root: root)
    if let description {
        let package = try JSONDecoder().decode(PackageDescription.self, from: readFile(description))
        guard base == root || base.hasPrefix(root + "/") else {
            throw Failure("--base \(base) lies outside --root \(root)")
        }
        let unindexed = presence.unindexedTargets(of: package, at: String(base.dropFirst(root.count + 1)))
        guard unindexed.isEmpty else { throw BundleError.unindexedTargets(store: store, targets: unindexed) }
    }

    let periphery = try options.required("periphery")
    func view(_ arguments: [String]) throws -> [Finding] {
        try JSONDecoder().decode([Finding].self, from: runProcess(periphery, arguments, in: base))
            .map { try $0.normalized(root: root, base: base) }
    }
    let bundle = try PlatformBundle(
        full: try view(scan.full), production: try view(scan.production), presence: presence,
        source: { try String(contentsOfFile: root + "/" + $0, encoding: .utf8) })
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
        throw Failure("\(exporter) exited \(process.terminationStatus) exporting \(store)")
    }
    guard !filter.presence.keys.isEmpty else { throw BundleError.emptyStore(store: store, root: root) }
    return filter.presence
}

runCommand(
    tool: "dead-code-sources", usage: usage,
    [
        "bundle": { try bundle(Options($0, usage: usage)) }
    ])
