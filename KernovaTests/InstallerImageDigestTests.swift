import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("InstallerImageDigest Tests", .caseScoped)
struct InstallerImageDigestTests {
    private static let manifestURL = URL(
        string: "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/CHECKSUM")!
    private static let digest = String(repeating: "ab", count: 32)

    @Test("A matching digest yields a record carrying the source it matched")
    func matchRecordsSource() {
        let expected = ExpectedDigest(sha256: Self.digest, source: .checksumList(Self.manifestURL))

        let record = expected.match(Self.digest, filename: "Fedora-44.iso")

        #expect(record?.matched == .checksumList(Self.manifestURL))
        #expect(record?.sha256 == Self.digest)
        #expect(record?.filename == "Fedora-44.iso")
    }

    @Test("A differing digest yields no record")
    func mismatchYieldsNothing() {
        let expected = ExpectedDigest(sha256: Self.digest, source: .enteredByUser)

        #expect(expected.match(String(repeating: "0", count: 64), filename: "a.iso") == nil)
    }

    @Test("Case does not decide a match, and the record is lowercase")
    func matchIgnoresCase() {
        let expected = ExpectedDigest(sha256: Self.digest.uppercased(), source: .enteredByUser)

        #expect(expected.sha256 == Self.digest)
        let record = expected.match(Self.digest.uppercased(), filename: "a.iso")
        #expect(record?.sha256 == Self.digest)
        #expect(record?.matched == .enteredByUser)
    }

    @Test("An unchecked digest matched nothing")
    func uncheckedMatchedNothing() {
        let record = InstallerImageDigest.unchecked(
            filename: "a.iso", sha256: Self.digest.uppercased())

        #expect(record.matched == nil)
        #expect(record.sha256 == Self.digest)
    }

    @Test("A checksum list is named by its own host")
    func checksumListPhrase() {
        #expect(
            DigestSource.checksumList(Self.manifestURL).phrase
                == "the checksum list on dl.fedoraproject.org")
    }

    @Test("A typed checksum is named as the user's")
    func enteredPhrase() {
        #expect(DigestSource.enteredByUser.phrase == "the checksum you entered")
    }
}
