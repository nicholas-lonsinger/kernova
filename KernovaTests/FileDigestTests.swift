import CryptoKit
import Foundation
import Testing

@testable import Kernova

@Suite("FileDigest Tests")
@MainActor
struct FileDigestTests {
    /// Collects the main-actor progress callbacks for assertion after the fact.
    @MainActor private final class Samples {
        private(set) var values: [Double] = []
        func append(_ value: Double) { values.append(value) }
    }

    /// Writes `contents` to a throwaway file and hands back its URL.
    private func makeFile(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDigestTests-\(UUID().uuidString).bin")
        try contents.write(to: url)
        return url
    }

    @Test("The digest matches the published SHA-256 of 'abc'")
    func knownDigest() async throws {
        // FIPS 180-2 test vector, so this asserts against the algorithm rather
        // than against a second call into CryptoKit.
        let url = try makeFile(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let digest = try await FileDigest.sha256(of: url) { _ in }

        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("An empty file digests to the published empty-input hash")
    func emptyFile() async throws {
        let url = try makeFile(Data())
        defer { try? FileManager.default.removeItem(at: url) }

        let digest = try await FileDigest.sha256(of: url) { _ in }

        #expect(digest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("A file spanning several chunks digests the same as one read whole")
    func multipleChunks() async throws {
        // Deliberately longer than `chunkByteCount`, which is the whole reason
        // this reads incrementally rather than through `Data(contentsOf:)`.
        var contents = Data(count: FileDigest.chunkByteCount + 7)
        for index in stride(from: 0, to: contents.count, by: 4096) {
            contents[index] = UInt8(index % 251)
        }
        let url = try makeFile(contents)
        defer { try? FileManager.default.removeItem(at: url) }

        let digest = try await FileDigest.sha256(of: url) { _ in }

        let whole = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        #expect(digest == whole)
    }

    @Test("Progress finishes at 1 for a file that was read")
    func progressReachesOne() async throws {
        let url = try makeFile(Data("kernova".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = Samples()
        _ = try await FileDigest.sha256(of: url) { fraction in samples.append(fraction) }

        #expect(samples.values.last == 1)
        #expect(samples.values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("A missing file surfaces the read failure")
    func missingFile() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDigestTests-absent-\(UUID().uuidString).bin")

        await #expect(throws: (any Error).self) {
            try await FileDigest.sha256(of: url) { _ in }
        }
    }
}
