import DeadCodeKit
import Foundation
import Testing

@Suite struct PresenceTests {
    private let rows = """
        s:4Kit3FooV\tdefinition\t/repo/KernovaKit/Sources/Kit/Foo.swift\t3\t8
        s:4Kit3FooV\treference\t/repo/KernovaKit/Sources/Kit/Bar.swift\t9\t14
        c:@M@KernovaWire\treference\t/repo/KernovaKit/Sources/Kit/Bar.swift\t2\t8
        s:4Kit3BarV\tdeclaration\t/repo/Kernova/App.swift\t5\t6
        s:4Kit3FooV\tdefinition\t/repo/KernovaKit/.build/checkouts/x/X.swift\t1\t1
        s:4Kit3FooV\tdefinition\t/repo/DerivedData/Periphery/SourcePackages/checkouts/y/Y.swift\t1\t1
        s:4Kit3FooV\tdefinition\t/elsewhere/Z.swift\t1\t1
        s:4Kit3BazV\tdefinition\t/repo/KernovaKit/Sources/Kit/Baz.swift\t7\t12
        """

    private var expected: Presence {
        Presence(keys: [
            .declaration(path: "KernovaKit/Sources/Kit/Foo.swift", line: 3, column: 8),
            .importStatement(path: "KernovaKit/Sources/Kit/Bar.swift", line: 2, module: "KernovaWire"),
            .declaration(path: "Kernova/App.swift", line: 5, column: 6),
            .declaration(path: "KernovaKit/Sources/Kit/Baz.swift", line: 7, column: 12),
        ])
    }

    @Test func theFilterKeepsDeclarationsAndImportsUnderTheRoot() {
        var filter = PresenceFilter(root: "/repo/")
        filter.consume(Array(rows.utf8))
        filter.finish()
        #expect(filter.presence == expected)
    }

    @Test func aRowSplitAcrossChunksReadsWhole() {
        let bytes = Array((rows + "\n").utf8)
        for size in [1, 7, 64] {
            var filter = PresenceFilter(root: "/repo")
            var start = 0
            while start < bytes.count {
                filter.consume(bytes[start..<min(start + size, bytes.count)])
                start += size
            }
            filter.finish()
            #expect(filter.presence == expected, "chunks of \(size)")
        }
    }

    @Test func theTSVRoundTrips() throws {
        #expect(try Presence(tsv: expected.tsv) == expected)
    }
}

@Suite struct FindingTests {
    private func located(_ location: String) -> Finding {
        Finding(kind: "struct", name: "S", hints: ["unused"], location: parsed(location), ids: [])
    }

    @Test func anAbsolutePathLosesTheRoot() throws {
        let normalized = try located("/repo/Kernova/App.swift:4:8").normalized(root: "/repo/", base: "/repo")
        #expect(normalized.location.description == "Kernova/App.swift:4:8")
    }

    @Test func aRelativePathResolvesAgainstWherePeripheryRan() throws {
        let normalized = try located("Sources/Kit/Foo.swift:4:8").normalized(root: "/repo", base: "/repo/KernovaKit")
        #expect(normalized.location.description == "KernovaKit/Sources/Kit/Foo.swift:4:8")
    }

    @Test func aPathOutsideTheRootIsRefused() {
        #expect(throws: FindingError.outsideRoot(path: "/other/A.swift", root: "/repo")) {
            try located("/other/A.swift:1:1").normalized(root: "/repo", base: "/repo")
        }
    }

    @Test func peripheryJSONDecodes() throws {
        let json = """
            [{"accessibility": "internal", "attributes": [], "hints": ["unused"], "ids": ["s:x"],
              "kind": "var.instance", "location": "Sources/A.swift:368:9", "modifiers": [], "modules": ["A"],
              "name": "remoteRole"}]
            """
        let findings = try JSONDecoder().decode([Finding].self, from: Data(json.utf8))
        #expect(findings.map(\.key) == [.declaration(path: "Sources/A.swift", line: 368, column: 9)])
    }
}

@Suite struct BuildGraphTests {
    @Test func onlyWhatASchemeLaunchesOrAnExecutableHoldsIsProduction() throws {
        let project = [
            XcodeTarget(name: "App", dependencies: ["Helper", "Aggregate"], packageProducts: ["AppKit"]),
            XcodeTarget(name: "Helper", packageProducts: ["Logging"]),
            XcodeTarget(name: "Aggregate"),
            XcodeTarget(name: "AppTests", dependencies: ["App"], packageProducts: ["TestSupport"]),
            XcodeTarget(name: "TestHost"),
            XcodeTarget(name: "UITests", dependencies: ["TestHost"]),
        ]
        let package = PackageDescription(
            products: [
                .init(name: "AppKit", isExecutable: false, targets: ["AppKit", "Wire"]),
                .init(name: "Logging", isExecutable: false, targets: ["Logging"]),
                .init(name: "TestSupport", isExecutable: false, targets: ["TestSupport"]),
                .init(name: "agent", isExecutable: true, targets: ["Agent"]),
            ],
            targets: [
                .init(name: "AppKit", targetDependencies: ["Wire"]),
                .init(name: "Wire", productDependencies: ["SwiftProtobuf"]),
                .init(name: "Logging"),
                .init(name: "Agent", targetDependencies: ["Linux"]),
                .init(name: "Linux"),
                .init(name: "Host"),
                .init(name: "TestSupport", targetDependencies: ["Simulation"]),
                .init(name: "Simulation", targetDependencies: ["Wire"]),
                .init(name: "WireTests", targetDependencies: ["Wire", "Simulation"]),
            ])
        let downstream = PackageDescription(
            products: [.init(name: "Core", isExecutable: false, targets: ["Core"])],
            targets: [.init(name: "Core", productDependencies: ["AppKit"]), .init(name: "CoreTests")])

        let testOnly = try testOnlyTargets(
            project: project + [XcodeTarget(name: "Shell", packageProducts: ["Core"])],
            packages: [package, downstream], schemes: ["App": ["App"], "Shell": ["Shell"]])
        #expect(
            testOnly == [
                "AppTests", "CoreTests", "Host", "Simulation", "TestHost", "TestSupport", "UITests", "WireTests",
            ])
    }

    @Test func aSchemeNamingNoTargetIsRefused() {
        #expect(throws: BuildGraphError.unknownSchemeTarget(scheme: "Gone", target: "Gone")) {
            try testOnlyTargets(project: [], packages: [], schemes: ["Gone": ["Gone"]])
        }
    }

    @Test func aSchemeLaunchesWhatItBuildsToRunOrArchive() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Scheme>
               <BuildAction parallelizeBuildables = "YES">
                  <BuildActionEntries>
                     <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForArchiving = "YES">
                        <BuildableReference BuildableIdentifier = "primary" BlueprintName = "App"/>
                     </BuildActionEntry>
                     <BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForArchiving = "NO">
                        <BuildableReference BuildableIdentifier = "primary" BlueprintName = "AppTests"/>
                     </BuildActionEntry>
                  </BuildActionEntries>
               </BuildAction>
               <TestAction>
                  <Testables>
                     <TestableReference skipped = "NO">
                        <BuildableReference BuildableIdentifier = "primary" BlueprintName = "UITests"/>
                     </TestableReference>
                  </Testables>
               </TestAction>
               <LaunchAction>
                  <BuildableProductRunnable>
                     <BuildableReference BuildableIdentifier = "primary" BlueprintName = "App"/>
                  </BuildableProductRunnable>
               </LaunchAction>
            </Scheme>
            """
        #expect(try schemeLaunchTargets(xml: Data(xml.utf8), scheme: "App") == ["App"])
    }

    @Test func aPackageProductDecodesItsKind() throws {
        let json = """
            {"name": "KernovaKit", "products": [
               {"name": "kernova-agent", "type": {"executable": null}, "targets": ["KernovaLinuxAgent"]},
               {"name": "KernovaLogging", "type": {"library": ["static"]}, "targets": ["KernovaLogging"]}],
             "targets": [{"name": "KernovaLinuxAgent", "type": "executable", "module_type": "SwiftTarget",
                 "path": "Sources/KernovaLinuxAgent", "target_dependencies": ["KernovaDBus"]},
               {"name": "KernovaDBus", "type": "library", "module_type": "SwiftTarget", "path": "Sources/KernovaDBus"}]}
            """
        let package = try JSONDecoder().decode(PackageDescription.self, from: Data(json.utf8))
        #expect(package.products.map(\.isExecutable) == [true, false])
        #expect(package.targets.map(\.targetDependencies) == [["KernovaDBus"], []])
    }
}
