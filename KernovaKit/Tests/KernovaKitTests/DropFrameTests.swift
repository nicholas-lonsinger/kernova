import Foundation
import Testing

@testable import KernovaKit

/// Wire round-trip for the drag-and-drop frames, so a field number or type that
/// changes shape is caught here rather than by a guest that silently reads
/// nothing.
@Suite("Drop frames")
struct DropFrameTests {
    private func roundTrip(_ frame: Frame) throws -> Frame {
        try Frame(serializedBytes: frame.serializedData())
    }

    @Test("a drop offer round-trips its generation and every item's metadata")
    func offerRoundTrips() throws {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dropOffer = Kernova_V1_DropOffer.with {
            $0.generation = 7
            $0.repInfo = [
                Kernova_V1_ClipboardRepresentationInfo.with {
                    $0.uti = "public.png"
                    $0.byteCount = 4_096
                    $0.filename = "shot.png"
                },
                Kernova_V1_ClipboardRepresentationInfo.with {
                    $0.uti = "public.folder"
                    $0.byteCount = 1_000_000
                    $0.filename = "Photos"
                    $0.isDirectory = true
                },
            ]
        }

        let decoded = try roundTrip(frame)
        guard case .dropOffer(let offer) = decoded.payload else {
            Issue.record("Expected a drop offer payload")
            return
        }
        #expect(offer.generation == 7)
        #expect(offer.repInfo.count == 2)
        #expect(offer.repInfo[0].filename == "shot.png")
        #expect(offer.repInfo[0].byteCount == 4_096)
        #expect(offer.repInfo[1].isDirectory)
        #expect(offer.repInfo[1].uti == "public.folder")
    }

    @Test("every completion outcome round-trips, carrying its code only when it failed")
    func completeRoundTrips() throws {
        for outcome in [
            Kernova_V1_DropComplete.Outcome.completed, .cancelled, .failed,
        ] {
            var frame = Frame()
            frame.protocolVersion = 1
            frame.dropComplete = Kernova_V1_DropComplete.with {
                $0.generation = 3
                $0.outcome = outcome
                if outcome == .failed {
                    $0.code = ClipboardErrorCode.dropDiskFull.rawValue
                    $0.message = "no room"
                }
            }

            let decoded = try roundTrip(frame)
            guard case .dropComplete(let complete) = decoded.payload else {
                Issue.record("Expected a drop completion payload")
                return
            }
            #expect(complete.generation == 3)
            #expect(complete.outcome == outcome)
            #expect(
                complete.code
                    == (outcome == .failed ? ClipboardErrorCode.dropDiskFull.rawValue : ""))
        }
    }

    @Test("a drop release round-trips its generation")
    func releaseRoundTrips() throws {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dropRelease = Kernova_V1_DropRelease.with { $0.generation = 11 }

        let decoded = try roundTrip(frame)
        guard case .dropRelease(let release) = decoded.payload else {
            Issue.record("Expected a drop release payload")
            return
        }
        #expect(release.generation == 11)
    }

    @Test("the drop payloads occupy the field numbers the proto reserves for them")
    func usesTheReservedFieldNumbers() throws {
        // A renumbering would decode as an unknown field on a peer built from
        // the previous proto — silently, which is what this pins.
        var offer = Frame()
        offer.dropOffer = Kernova_V1_DropOffer()
        var complete = Frame()
        complete.dropComplete = Kernova_V1_DropComplete()
        var release = Frame()
        release.dropRelease = Kernova_V1_DropRelease()

        // Field 40/41/42 with wire type 2 encodes as the tag byte pair below.
        #expect(Array(try offer.serializedData()).prefix(2) == [0xC2, 0x02])
        #expect(Array(try complete.serializedData()).prefix(2) == [0xCA, 0x02])
        #expect(Array(try release.serializedData()).prefix(2) == [0xD2, 0x02])
    }
}
