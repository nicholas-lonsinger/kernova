import Testing
import Foundation
@testable import Kernova

@Suite("PathValidation Tests")
struct PathValidationTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - resolveFile

    @Test("resolveFile succeeds for an existing regular file")
    func resolveFileSuccess() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let filePath = dir.appendingPathComponent("test.img").path(percentEncoded: false)
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
                  case .notFound = failure else { return false }
            return true
        }
    }

    @Test("resolveFile throws unexpectedType for a directory")
    func resolveFileDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect {
            try PathValidation.resolveFile(at: dir.path(percentEncoded: false))
        } throws: { error in
            guard let failure = error as? PathValidation.Failure,
                  case .unexpectedType = failure else { return false }
            return true
        }
    }

    @Test("resolveFile follows symlink to real file")
    func resolveFileFollowsSymlink() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let realPath = dir.appendingPathComponent("real.img").path(percentEncoded: false)
        FileManager.default.createFile(atPath: realPath, contents: Data([0]))

        let linkPath = dir.appendingPathComponent("link.img").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: realPath)

        let resolved = try PathValidation.resolveFile(at: linkPath)
        #expect(resolved.wasSymlink == true)
        #expect(resolved.originalPath == linkPath)
        #expect(resolved.url.lastPathComponent == "real.img")
    }

    @Test("resolveFile throws notFound for dangling symlink")
    func resolveFileDanglingSymlink() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let linkPath = dir.appendingPathComponent("dangling.img").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: "/nonexistent/target")

        #expect {
            try PathValidation.resolveFile(at: linkPath)
        } throws: { error in
            guard let failure = error as? PathValidation.Failure,
                  case .notFound = failure else { return false }
            return true
        }
    }

    // MARK: - resolveDirectory

    @Test("resolveDirectory succeeds for an existing directory")
    func resolveDirectorySuccess() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolved = try PathValidation.resolveDirectory(at: dir.path(percentEncoded: false))
        #expect(resolved.wasSymlink == false)
    }

    @Test("resolveDirectory throws unexpectedType for a regular file")
    func resolveDirectoryFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let filePath = dir.appendingPathComponent("file.txt").path(percentEncoded: false)
        FileManager.default.createFile(atPath: filePath, contents: Data([0]))

        #expect {
            try PathValidation.resolveDirectory(at: filePath)
        } throws: { error in
            guard let failure = error as? PathValidation.Failure,
                  case .unexpectedType = failure else { return false }
            return true
        }
    }

    @Test("resolveDirectory throws notFound for nonexistent path")
    func resolveDirectoryNotFound() throws {
        #expect {
            try PathValidation.resolveDirectory(at: "/nonexistent/directory")
        } throws: { error in
            guard let failure = error as? PathValidation.Failure,
                  case .notFound = failure else { return false }
            return true
        }
    }

    // MARK: - ResolvedPath

    @Test("ResolvedPath wasSymlink is false when paths match")
    func resolvedPathNotSymlink() {
        let path = "/tmp/test"
        let resolved = PathValidation.ResolvedPath(
            url: URL(fileURLWithPath: path),
            resolvedPath: path,
            originalPath: path
        )
        #expect(resolved.wasSymlink == false)
    }

    @Test("ResolvedPath wasSymlink is true when paths differ")
    func resolvedPathIsSymlink() {
        let resolved = PathValidation.ResolvedPath(
            url: URL(fileURLWithPath: "/real/path"),
            resolvedPath: "/real/path",
            originalPath: "/link/path"
        )
        #expect(resolved.wasSymlink == true)
    }
}
