import CryptoKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("FileDigest Tests", .caseScoped)
@MainActor
struct FileDigestTests {
    /// Collects the main-actor progress callbacks for assertion after the fact.
    @MainActor private final class Samples {
        private(set) var values: [Double] = []
        func append(_ value: Double) { values.append(value) }
    }

    private let scratch = TestScratchDirectory(prefix: "FileDigestTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    /// Writes `contents` to a throwaway file and hands back its URL.
    private func makeFile(_ contents: Data) throws -> URL {
        let url = scratch.url.appendingPathComponent("\(UUID().uuidString).bin")
        try contents.write(to: url)
        return url
    }

    @Test("A file spanning several chunks digests the same as one read whole")
    func multipleChunks() async throws {
        // Longer than `chunkByteCount`, so the digest takes more than one read.
        var contents = Data(count: FileDigest.chunkByteCount + 7)
        for index in stride(from: 0, to: contents.count, by: 4096) {
            contents[index] = UInt8(index % 251)
        }
        let url = try makeFile(contents)

        let digest = try await FileDigest.sha256(of: url)

        let whole = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        #expect(digest == whole)
    }

    @Test("Progress finishes at 1 for a file that was read")
    func progressReachesOne() async throws {
        let url = try makeFile(Data("kernova".utf8))

        let samples = Samples()
        _ = try await FileDigest.sha256(of: url) { fraction in samples.append(fraction) }

        #expect(samples.values.last == 1)
        #expect(samples.values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }
}
