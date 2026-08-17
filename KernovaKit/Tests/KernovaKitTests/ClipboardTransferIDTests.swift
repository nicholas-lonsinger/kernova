import Foundation
import Testing

@testable import KernovaKit

@Suite("ClipboardTransferID")
struct ClipboardTransferIDTests {
    @Test("ids encode (generation, repIndex, direction) and decode their generation")
    func roundTrips() {
        for generation: UInt64 in [1, 42, 65_535, 1 << 30] {
            for repIndex in [0, 1, 0xFFFF] {
                let guestID = ClipboardTransferID.make(
                    generation: generation, repIndex: repIndex, hostMinted: false)
                let hostID = ClipboardTransferID.make(
                    generation: generation, repIndex: repIndex, hostMinted: true)
                #expect(!ClipboardTransferID.hostReceives(guestID))
                #expect(ClipboardTransferID.hostReceives(hostID))
                #expect(ClipboardTransferID.generation(of: guestID) == generation)
                #expect(ClipboardTransferID.generation(of: hostID) == generation)
                // The layout — rep index in the low 16 bits, direction bit
                // ignored.
                #expect(ClipboardTransferID.repIndex(of: guestID) == repIndex)
                #expect(ClipboardTransferID.repIndex(of: hostID) == repIndex)
            }
        }
    }

    @Test("determinism: re-deriving an id from the same key yields the same value")
    func determinism() {
        let first = ClipboardTransferID.make(generation: 9, repIndex: 4, hostMinted: true)
        let second = ClipboardTransferID.make(generation: 9, repIndex: 4, hostMinted: true)
        #expect(first == second)
    }
}
