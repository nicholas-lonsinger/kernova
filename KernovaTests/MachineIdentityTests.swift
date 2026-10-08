import Foundation
import Testing

@testable import Kernova

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

    @Test(
        "The same bytes fingerprint alike and different bytes differ, in either case",
        arguments: [MachineIdentity.mac(Data([1, 2, 3])), .generic(Data([1, 2, 3]))])
    func fingerprintFollowsTheBytes(identity: MachineIdentity) {
        let same: MachineIdentity
        let other: MachineIdentity
        switch identity {
        case .mac:
            same = .mac(Data([1, 2, 3]))
            other = .mac(Data([1, 2, 4]))
        case .generic:
            same = .generic(Data([1, 2, 3]))
            other = .generic(Data([1, 2, 4]))
        }
        #expect(identity.fingerprint == same.fingerprint)
        #expect(identity.fingerprint != other.fingerprint)
    }
}
