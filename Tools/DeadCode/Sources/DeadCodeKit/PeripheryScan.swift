import Foundation

/// One platform's two Periphery scans over one index store.
///
/// Periphery reads no build of its own and is always handed the store, so the store a bundle exports its presence
/// from is the store its findings came from: a store Periphery cannot read, which it reports as no findings at all,
/// is one the presence export refuses.
package struct PeripheryScan: Equatable, Sendable {
    /// `.periphery.yml`, the analysis every platform shares.
    package var configuration: String
    package var store: String
    /// For a package, `swift package describe --type json` as built, which Periphery then reads instead of
    /// describing the package with whatever toolchain it finds.
    package var packageDescription: String?
    /// What to scan: the project and its schemes, or nothing for the package in the directory Periphery runs in.
    package var arguments: [String]
    /// Left out of the production view.
    package var testOnlyTargets: [String]

    package init(
        configuration: String, store: String, packageDescription: String? = nil, arguments: [String] = [],
        testOnlyTargets: [String]
    ) throws(BundleError) {
        guard !testOnlyTargets.isEmpty else { throw .noTestOnlyTargets }
        self.configuration = configuration
        self.store = store
        self.packageDescription = packageDescription
        self.arguments = arguments
        self.testOnlyTargets = testOnlyTargets
    }

    /// The scan with test targets built.
    package var full: [String] { common }

    /// The scan with every target only tests reach excluded.
    package var production: [String] { common + ["--exclude-targets"] + testOnlyTargets }

    private var common: [String] {
        [
            "scan", "--config", configuration, "--disable-update-check", "--quiet", "--format", "json",
            "--skip-build", "--index-store-path", store,
        ] + (packageDescription.map { ["--json-package-manifest-path", $0] } ?? []) + arguments
    }
}

extension Presence {
    /// The Swift targets of `package`, which lies at `directory` relative to the repository root, whose sources hold
    /// no declaration this index compiled: the index is not the build of every target the package declares.
    ///
    /// A C target is not looked for: its declarations reach no Swift index.
    package func unindexedTargets(of package: PackageDescription, at directory: String) -> [String] {
        var paths = Set<String>()
        for case .declaration(let path, _, _) in keys { paths.insert(path) }
        let base = directory.isEmpty ? "" : directory.trimmingSlash + "/"
        return package.targets.filter(\.isSwift).filter { target in
            let prefix = base + target.path.trimmingSlash + "/"
            return !paths.contains { $0.hasPrefix(prefix) }
        }.map(\.name).sorted()
    }
}
