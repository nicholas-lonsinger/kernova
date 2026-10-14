import Testing
import Foundation
@testable import Kernova

@Suite("PathValidation Tests", .caseScoped)
struct PathValidationTests {
    private let scratch = TestScratchDirectory(prefix: "PathValidationTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    // MARK: - resolveFile

    @Test("resolveFile succeeds for an existing regular file")
    func resolveFileSuccess() throws {
        let filePath = scratch.url.appendingPathComponent("test.img").path(percentEncoded: false)
        FileManager.default.createFile(atPath: filePath, contents: Data([0]))

        let resolved = try PathValidation.resolveFile(at: filePath)
        #expect(resolved.resolvedPath == filePath)
        #expect(resolved.wasSymlink == false)
    }

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

    @Test("resolveFile throws unexpectedType for a directory")
    func resolveFileDirectory() throws {
        #expect {
            try PathValidation.resolveFile(at: scratch.url.path(percentEncoded: false))
        } throws: { error in
            guard let failure = error as? PathValidation.Failure,
                case .unexpectedType = failure
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

    @Test("resolveFile throws notFound for dangling symlink")
    func resolveFileDanglingSymlink() throws {
        let linkPath = scratch.url.appendingPathComponent("dangling.img").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: "/nonexistent/target")

        #expect {
            try PathValidation.resolveFile(at: linkPath)
        } throws: { error in
            guard let failure = error as? PathValidation.Failure,
                case .notFound = failure
            else { return false }
            return true
        }
    }

    // MARK: - resolveDirectory

    @Test("resolveDirectory succeeds for an existing directory")
    func resolveDirectorySuccess() throws {
        let resolved = try PathValidation.resolveDirectory(at: scratch.url.path(percentEncoded: false))
        #expect(resolved.wasSymlink == false)
    }

    @Test("resolveDirectory throws unexpectedType for a regular file")
    func resolveDirectoryFile() throws {
        let filePath = scratch.url.appendingPathComponent("file.txt").path(percentEncoded: false)
        FileManager.default.createFile(atPath: filePath, contents: Data([0]))

        #expect {
            try PathValidation.resolveDirectory(at: filePath)
        } throws: { error in
            guard let failure = error as? PathValidation.Failure,
                case .unexpectedType = failure
            else { return false }
            return true
        }
    }

    @Test("resolveDirectory throws notFound for nonexistent path")
    func resolveDirectoryNotFound() throws {
        #expect {
            try PathValidation.resolveDirectory(at: "/nonexistent/directory")
        } throws: { error in
            guard let failure = error as? PathValidation.Failure,
                case .notFound = failure
            else { return false }
            return true
        }
    }
}
