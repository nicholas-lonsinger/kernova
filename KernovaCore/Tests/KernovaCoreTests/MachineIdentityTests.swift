import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("MachineIdentity Tests", .caseScoped)
struct MachineIdentityTests {
    @Test(
        "A fingerprint is the SHA-256 in uppercase hex, shown as its first eight digits",
        arguments: [MachineIdentity.mac(Data("abc".utf8)), .generic(Data("abc".utf8))])
    func fingerprintIsTheDigest(identity: MachineIdentity) {
        // SHA-256("abc"), the FIPS 180-2 test vector.
        let digest = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
        #expect(identity.fingerprint.digest == digest)
        #expect(identity.fingerprint.short == "BA78-16BF")
    }
}
