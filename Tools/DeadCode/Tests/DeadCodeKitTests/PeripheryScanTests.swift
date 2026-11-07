import DeadCodeKit
import Foundation
import Testing

@Suite struct PeripheryScanTests {
    /// Periphery reports a store it cannot read as no findings, so neither view may read any store but the one the
    /// presence comes from, nor build one of its own.
    @Test func bothViewsReadTheBundlesStoreAndBuildNothing() throws {
        let scan = try PeripheryScan(
            configuration: "/repo/.periphery.yml", store: "/repo/KernovaKit/.build/x/index/store",
            packageDescription: "/tmp/package.json", testOnlyTargets: ["KernovaWireTests", "KernovaAgentSimulation"])
        for view in [scan.full, scan.production] {
            let store = try #require(view.firstIndex(of: "--index-store-path"))
            #expect(view[store + 1] == "/repo/KernovaKit/.build/x/index/store")
            #expect(view.contains("--skip-build"))
            #expect(view.filter { $0 == "--index-store-path" }.count == 1)
            let description = try #require(view.firstIndex(of: "--json-package-manifest-path"))
            #expect(view[description + 1] == "/tmp/package.json")
        }
        #expect(!scan.full.contains("--exclude-targets"))
        #expect(scan.production.suffix(3) == ["--exclude-targets", "KernovaWireTests", "KernovaAgentSimulation"])
    }

    @Test func aProjectScanCarriesItsArguments() throws {
        let scan = try PeripheryScan(
            configuration: "/repo/.periphery.yml", store: "/store",
            arguments: ["--project", "Kernova.xcodeproj", "--schemes", "Kernova"], testOnlyTargets: ["KernovaTests"])
        #expect(!scan.full.contains("--json-package-manifest-path"))
        #expect(scan.full.suffix(4) == ["--project", "Kernova.xcodeproj", "--schemes", "Kernova"])
    }

    @Test func noTestOnlyTargetIsRefused() {
        #expect(throws: BundleError.noTestOnlyTargets) {
            try PeripheryScan(configuration: "/repo/.periphery.yml", store: "/store", testOnlyTargets: [])
        }
    }
}

@Suite struct UnindexedTargetsTests {
    private let package = PackageDescription(
        products: [],
        targets: [
            .init(name: "Kit"),
            .init(name: "Wire"),
            .init(name: "KitTests", path: "Tests/KitTests"),
            .init(name: "CShims", isSwift: false),
        ])

    private func presence(_ paths: String...) -> Presence {
        Presence(keys: Set(paths.map { .declaration(path: $0, line: 1, column: 1) }))
    }

    @Test func everySwiftTargetIndexedClaimsNothingMissing() {
        let store = presence(
            "KernovaKit/Sources/Kit/A.swift", "KernovaKit/Sources/Wire/B.swift", "KernovaKit/Tests/KitTests/C.swift")
        #expect(store.unindexedTargets(of: package, at: "KernovaKit").isEmpty)
    }

    /// A store from a build without the tests, or of other code entirely, names what it lacks; a C target, whose
    /// declarations reach no Swift index, is never one of them.
    @Test func aTargetWithNoDeclarationIsNamed() {
        let withoutTests = presence("KernovaKit/Sources/Kit/A.swift", "KernovaKit/Sources/Wire/B.swift")
        #expect(withoutTests.unindexedTargets(of: package, at: "KernovaKit") == ["KitTests"])
        let elsewhere = presence("Kernova/App.swift", "KernovaKit/Sources/KitExtras/D.swift")
        #expect(elsewhere.unindexedTargets(of: package, at: "KernovaKit") == ["Kit", "KitTests", "Wire"])
    }

    @Test func theTargetsOfDescribeDecode() throws {
        let json = """
            {"name": "KernovaKit", "products": [], "targets": [
              {"name": "Kit", "type": "library", "module_type": "SwiftTarget", "path": "Sources/Kit"},
              {"name": "CShims", "type": "library", "module_type": "ClangTarget", "path": "Sources/CShims"}
            ]}
            """
        let package = try JSONDecoder().decode(PackageDescription.self, from: Data(json.utf8))
        #expect(package.targets.map(\.isSwift) == [true, false])
        #expect(presence("KernovaKit/Sources/Kit/A.swift").unindexedTargets(of: package, at: "KernovaKit").isEmpty)
    }
}
