import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("PathValidation Tests", .caseScoped)
struct PathValidationTests {
    private let scratch = TestScratchDirectory(prefix: "PathValidationTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    // MARK: - resolveFile

    @Test("resolveFile throws notFound for nonexistent path")
    func resolveFileNotFound() throws {
        #expect {
            try PathValidation.resolveFile(at: "/nonexistent/path/file.img")
        } throws: { error in
            guard let failure = error as? PathValidation.Failure,
                case .notFound = failure
            else { return false }
            return true
        }
    }

    @Test("resolveFile follows symlink to real file")
    func resolveFileFollowsSymlink() throws {
        let realPath = scratch.url.appendingPathComponent("real.img").path(percentEncoded: false)
        FileManager.default.createFile(atPath: realPath, contents: Data([0]))

        let linkPath = scratch.url.appendingPathComponent("link.img").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: realPath)

        let resolved = try PathValidation.resolveFile(at: linkPath)
        #expect(resolved.wasSymlink == true)
        #expect(resolved.originalPath == linkPath)
        #expect(resolved.url.lastPathComponent == "real.img")
    }

    // MARK: - resolveDirectory

    @Test("resolveDirectory succeeds for an existing directory")
    func resolveDirectorySuccess() throws {
        let resolved = try PathValidation.resolveDirectory(at: scratch.url.path(percentEncoded: false))
        #expect(resolved.wasSymlink == false)
    }
}
