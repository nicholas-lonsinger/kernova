import KernovaDigest
import Testing

@Suite("SHA-256")
struct SHA256Tests {
    /// FIPS 180-4's examples (NIST's SHA256.pdf, "Example Algorithms") and the long-message vectors of
    /// the NIST CSRC "SHA-2" test vectors.
    @Test(
        "The FIPS 180-4 example vectors",
        arguments: [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
            ),
            (
                "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
                "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
            ),
        ])
    func vectors(message: String, digest: String) {
        #expect(lowercaseHex(KernovaDigest.SHA256.hash(Array(message.utf8))) == digest)
    }

    @Test("Hex reads back two digits a byte, either case, and refuses anything else")
    func hexBytes() {
        #expect(bytes(fromHex: "000fa0ff") == [0x00, 0x0F, 0xA0, 0xFF])
        #expect(bytes(fromHex: "A0Ff") == [0xA0, 0xFF])
        #expect(bytes(fromHex: "") == [])
        #expect(bytes(fromHex: "abc") == nil)
        #expect(bytes(fromHex: "zz") == nil)
    }
}
