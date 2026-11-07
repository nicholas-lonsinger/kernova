import DeadCodeKit
import Foundation
import Testing

private func finding(
    _ location: String, _ hint: String = "unused", kind: String = "function.free", name: String = "f",
    ids: [String] = ["s:f"]
) -> Finding {
    Finding(kind: kind, name: name, hints: [hint], location: parsed(location), ids: ids)
}

/// `text` as a location, recording an issue when it is not one.
func parsed(_ text: String) -> FileLocation {
    guard let location = FileLocation(text) else {
        Issue.record("not path:line:column: \(text)")
        return FileLocation(path: text, line: 0, column: 0)
    }
    return location
}

private func declared(_ locations: String...) -> Presence {
    Presence(
        keys: Set(
            locations.map { text in
                let location = parsed(text)
                return .declaration(path: location.path, line: location.line, column: location.column)
            }))
}

@Suite struct CombineTests {
    @Test func aFindingAnotherPlatformCompilesWithoutReportingIsDropped() throws {
        let combined = try combine([
            PlatformScan(platform: .macos, findings: [finding("A.swift:1:6")], presence: declared("A.swift:1:6")),
            PlatformScan(platform: .linux, findings: [], presence: declared("A.swift:1:6")),
        ])
        #expect(combined.isEmpty)
    }

    @Test func aFindingAnotherPlatformDoesNotCompileStands() throws {
        let combined = try combine([
            PlatformScan(platform: .macos, findings: [finding("A.swift:1:6")], presence: declared("A.swift:1:6")),
            PlatformScan(platform: .linux, findings: [], presence: declared("A.swift:9:6")),
        ])
        #expect(combined.map(\.states) == [[.macos: .reported(["unused"]), .linux: .absent]])
        #expect(combined.first?.compiledOnly(among: [.macos, .linux]) == [.macos])
    }

    /// `Foo+Darwin.swift` and `Foo+Linux.swift` declare the same USR; each is judged where it is.
    @Test func twinsSharingAUSRAreJudgedByLocation() throws {
        let darwin = finding("Foo+Darwin.swift:3:10", ids: ["s:shared"])
        let combined = try combine([
            PlatformScan(platform: .macos, findings: [darwin], presence: declared("Foo+Darwin.swift:3:10")),
            PlatformScan(platform: .linux, findings: [], presence: declared("Foo+Linux.swift:3:10")),
        ])
        #expect(combined.map(\.key) == [.declaration(path: "Foo+Darwin.swift", line: 3, column: 10)])
    }

    @Test func theCombinedHintIsTheMostUsedOne() throws {
        let combined = try combine([
            PlatformScan(platform: .macos, findings: [finding("A.swift:1:6")], presence: declared("A.swift:1:6")),
            PlatformScan(
                platform: .linux, findings: [finding("A.swift:1:6", "redundantPublicAccessibility")],
                presence: declared("A.swift:1:6")),
        ])
        #expect(combined.map(\.hints) == [["redundantPublicAccessibility"]])
    }

    @Test func anImportIsJudgedByItsLineAndModule() throws {
        let unusedImport = finding("A.swift:2:1", kind: "module", name: "KernovaKit")
        let imports = Presence(keys: [.importStatement(path: "A.swift", line: 2, module: "KernovaKit")])
        let usedOnLinux = try combine([
            PlatformScan(platform: .macos, findings: [unusedImport], presence: imports),
            PlatformScan(platform: .linux, findings: [], presence: imports),
        ])
        #expect(usedOnLinux.isEmpty)

        let otherModule = Presence(keys: [.importStatement(path: "A.swift", line: 2, module: "Glibc")])
        let notImportedOnLinux = try combine([
            PlatformScan(platform: .macos, findings: [unusedImport], presence: imports),
            PlatformScan(platform: .linux, findings: [], presence: otherModule),
        ])
        #expect(notImportedOnLinux.map(\.name) == ["KernovaKit"])
    }

    @Test func aConformanceStandsWithItsRedundantProtocol() throws {
        let protocolFinding = finding("P.swift:1:10", "redundantProtocol", kind: "protocol", name: "P", ids: ["s:P"])
        let conformance = finding("S.swift:4:12", "redundantConformance", kind: "protocol", name: "P", ids: ["s:P"])
        let kept = try combine([
            PlatformScan(
                platform: .macos, findings: [protocolFinding, conformance], presence: declared("P.swift:1:10")),
            PlatformScan(platform: .linux, findings: [protocolFinding], presence: declared("P.swift:1:10")),
        ])
        #expect(kept.map(\.key.path) == ["P.swift", "S.swift"])

        let dropped = try combine([
            PlatformScan(
                platform: .macos, findings: [protocolFinding, conformance], presence: declared("P.swift:1:10")),
            PlatformScan(platform: .linux, findings: [], presence: declared("P.swift:1:10")),
        ])
        #expect(dropped.isEmpty)
    }

    @Test func aPresenceMissingItsOwnFindingsIsRefused() {
        #expect(throws: CombineError.unlistedFindings(.macos, ["A.swift:1:6"])) {
            try combine([
                PlatformScan(platform: .macos, findings: [finding("A.swift:1:6")], presence: Presence()),
                PlatformScan(platform: .linux, findings: [], presence: declared("A.swift:1:6")),
            ])
        }
    }

    @Test func combiningPlatformsNeedsEachOnesPresence() {
        #expect(throws: CombineError.missingPresence(.linux)) {
            try combine([
                PlatformScan(platform: .macos, findings: [], presence: Presence()),
                PlatformScan(platform: .linux, findings: [], presence: nil),
            ])
        }
    }

    @Test func oneScanStandsAloneWithoutPresence() throws {
        let combined = try combine([PlatformScan(platform: .macos, findings: [finding("A.swift:1:6")], presence: nil)])
        #expect(combined.count == 1)
    }
}

@Suite struct ReportTests {
    private func scans(_ findings: [Finding], linux: [Finding] = []) -> [PlatformScan] {
        let presence = declared("A.swift:1:6", "B.swift:1:6", "C.swift:1:6")
        return [
            PlatformScan(platform: .macos, findings: findings, presence: presence),
            PlatformScan(platform: .linux, findings: linux, presence: presence),
        ]
    }

    @Test func testOnlyIsWhatProductionReportsAndTheFullScanDoesNot() throws {
        let deadEverywhere = finding("A.swift:1:6")
        let onlyTestsCall = finding("B.swift:1:6")
        let onlyTestsReachPublicly = finding("C.swift:1:6", "redundantPublicAccessibility")
        let report = try DeadCodeReport(
            full: scans([deadEverywhere, onlyTestsReachPublicly], linux: [deadEverywhere, onlyTestsReachPublicly]),
            production: scans(
                [deadEverywhere, onlyTestsCall, finding("C.swift:1:6")],
                linux: [deadEverywhere, onlyTestsCall, finding("C.swift:1:6")]))
        #expect(report.dead.map(\.key.path) == ["A.swift", "C.swift"])
        #expect(report.testOnly.map(\.key.path) == ["B.swift", "C.swift"])
        #expect(report.verdict == .findings)
        #expect(report.summary == "dead=2\ntest_only=2\nverdict=findings\n")
    }

    @Test func noFindingOnEveryPlatformIsClean() throws {
        let report = try DeadCodeReport(full: scans([]), production: scans([]))
        #expect(report.verdict == .clean)
    }

    @Test func aMissingPlatformIsPartialAndSaysSo() throws {
        let only = [PlatformScan(platform: .macos, findings: [], presence: nil)]
        let report = try DeadCodeReport(full: only, production: only)
        #expect(report.verdict == .partial)
        #expect(report.text.hasPrefix("This scan covers macOS uses only. Linux was not scanned"))
    }

    @Test func theMarkdownFitsItsLimit() throws {
        let many = (1...400).map { finding("Sources/File\($0).swift:\($0):6", name: "symbol\($0)") }
        let presence = Presence(keys: Set(many.map(\.key)))
        let scan = [
            PlatformScan(platform: .macos, findings: many, presence: presence),
            PlatformScan(platform: .linux, findings: many, presence: presence),
        ]
        let report = try DeadCodeReport(full: scan, production: scan)
        let markdown = report.markdown(limit: 5_000, rest: "the run's artifact")
        #expect(markdown.count <= 5_000)
        #expect(markdown.contains("the rest are in the run's artifact"))
        #expect(report.markdown(limit: 100_000, rest: "x").contains("symbol400"))
    }
}
