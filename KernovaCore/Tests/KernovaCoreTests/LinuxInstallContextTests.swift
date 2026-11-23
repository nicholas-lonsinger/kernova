import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("LinuxInstallContext Tests", .caseScoped)
struct LinuxInstallContextTests {
    @Test("A URL pick with a checksum is checked against what the user entered")
    func customURLChecksAgainstEnteredChecksum() async throws {
        let source = LinuxInstallContext.Source.customURL(
            CustomLinuxImage(
                url: URL(string: "https://mirror.example/alpine-3.22-aarch64.iso")!,
                sha256: String(repeating: "a", count: 64)))

        let (_, expected) = try await source.resolve(using: MockLinuxImageResolveService())

        #expect(
            expected == ExpectedDigest(sha256: String(repeating: "a", count: 64), source: .enteredByUser))
        #expect(source.digestSource == .enteredByUser)
    }
}
