import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("ClipboardFileStaging", .caseScoped)
struct ClipboardFileStagingTests {
    private let stagingRoot = TestStagingRoot()

    @Test("reserved directories ride the generation window (3 newest survive)")
    func reservationsRideGenerationWindow() throws {
        let staging = ClipboardFileStaging(label: "test-\(UUID().uuidString)", root: stagingRoot.root)

        var dirs: [URL] = []
        for generation in 1...4 {
            dirs.append(try staging.reserveScratchDirectory(generation: UInt64(generation)))
        }
        // Generation 1's directory is evicted when generation 4 arrives.
        #expect(!FileManager.default.fileExists(atPath: dirs[0].path))
        #expect(FileManager.default.fileExists(atPath: dirs[1].path))
        #expect(FileManager.default.fileExists(atPath: dirs[3].path))
    }
}
