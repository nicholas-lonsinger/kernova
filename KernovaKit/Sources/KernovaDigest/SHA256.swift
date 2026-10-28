/// SHA-256 (FIPS 180-4), fed incrementally.
///
/// The agents hash their own payloads with it; the host hashes the same files with CryptoKit, and the tests
/// hold the two to the same answers.
public struct SHA256: Sendable {
    /// The digest's length in bytes.
    public static let byteCount = 32

    private var state: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19
    )
    /// Bytes of an unfinished block; never a whole one.
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    /// A hash of no bytes yet.
    public init() {
        pending.reserveCapacity(64)
    }

    /// The digest of `bytes`.
    public static func hash(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        var hasher = SHA256()
        hasher.update(Array(bytes))
        return hasher.finalize()
    }

    /// Feeds `bytes`.
    public mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { update($0) }
    }

    /// Feeds `bytes`.
    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        length &+= UInt64(bytes.count)
        var offset = 0
        if !pending.isEmpty {
            let taken = min(64 - pending.count, bytes.count)
            pending.append(contentsOf: bytes[0..<taken])
            offset = taken
            guard pending.count == 64 else { return }
            pending.withUnsafeBytes { compress($0) }
            pending.removeAll(keepingCapacity: true)
        }
        while bytes.count - offset >= 64 {
            compress(UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + 64]))
            offset += 64
        }
        pending.append(contentsOf: bytes[offset...])
    }

    /// The digest of everything fed: 32 bytes. The hasher is spent.
    public consuming func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var tail: [UInt8] = [0x80]
        tail += [UInt8](repeating: 0, count: (55 &- pending.count) & 63)
        tail += (0..<8).map { UInt8(truncatingIfNeeded: bitLength >> (56 - 8 * $0)) }
        let savedLength = length
        update(tail)
        length = savedLength
        let words = [state.0, state.1, state.2, state.3, state.4, state.5, state.6, state.7]
        return words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (24 - 8 * $0)) } }
    }

    private mutating func compress(_ block: UnsafeRawBufferPointer) {
        var (a, b, c, d, e, f, g, h) = state
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 16) { words in
            for index in 0..<16 {
                words[index] = UInt32(bigEndian: block.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
            }
            for round in 0..<64 {
                let slot = round & 15
                if round >= 16 {
                    let w15 = words[(round - 15) & 15]
                    let w2 = words[(round - 2) & 15]
                    let s0 = rotate(w15, 7) ^ rotate(w15, 18) ^ (w15 >> 3)
                    let s1 = rotate(w2, 17) ^ rotate(w2, 19) ^ (w2 >> 10)
                    words[slot] = words[slot] &+ s0 &+ words[(round - 7) & 15] &+ s1
                }
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ choice &+ Self.k[round] &+ words[slot]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                (h, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ s0 &+ majority)
            }
        }
        state = (
            state.0 &+ a, state.1 &+ b, state.2 &+ c, state.3 &+ d, state.4 &+ e, state.5 &+ f, state.6 &+ g,
            state.7 &+ h
        )
    }

    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]
}

@inline(__always)
private func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
    (value >> count) | (value << (32 - count))
}
