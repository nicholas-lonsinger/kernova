import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// Wire round-trip for the drag-out frames, so a field number or type that
/// changes shape is caught here rather than by a peer that silently reads
/// nothing.
@Suite("Drag frames", .caseScoped)
struct DragFrameTests {
    private func roundTrip(_ frame: Frame) throws -> Frame {
        try Frame(serializedBytes: frame.serializedData())
    }

    @Test("a drag offer round-trips its generation and every item's metadata")
    func offerRoundTrips() throws {
        let frame = Frame.dragOffer(
            generation: 9,
            reps: [
                RepInfo(uti: "public.png", byteCount: 4_096, filename: "shot.png", isInline: false)
                    .wire,
                RepInfo(
                    uti: "public.folder", byteCount: 1_000, filename: "Photos", isInline: false,
                    isDirectory: true
                ).wire,
            ])

        let decoded = try roundTrip(frame)
        #expect(decoded.protocolVersion == 1)
        guard case .dragOffer(let offer) = decoded.payload else {
            Issue.record("Expected a drag offer payload")
            return
        }
        #expect(offer.generation == 9)
        #expect(offer.repInfo.map(\.filename) == ["shot.png", "Photos"])
        #expect(offer.repInfo[1].isDirectory)
    }

    @Test("the generation-only drag frames round-trip their generation")
    func generationFramesRoundTrip() throws {
        guard case .dragComplete(let complete) = try roundTrip(.dragComplete(generation: 3)).payload
        else {
            Issue.record("Expected a drag completion payload")
            return
        }
        #expect(complete.generation == 3)
        guard case .dragRelease(let release) = try roundTrip(.dragRelease(generation: 4)).payload
        else {
            Issue.record("Expected a drag release payload")
            return
        }
        #expect(release.generation == 4)
        guard case .dragTake(let take) = try roundTrip(.dragTake(generation: 5)).payload else {
            Issue.record("Expected a drag take payload")
            return
        }
        #expect(take.generation == 5)
    }

    @Test("a catcher frame round-trips its generation and whether to show it", arguments: [false, true])
    func catcherRoundTrips(shown: Bool) throws {
        guard
            case .dragCatcher(let catcher) = try roundTrip(.dragCatcher(generation: 8, shown: shown))
                .payload
        else {
            Issue.record("Expected a drag catcher payload")
            return
        }
        #expect(catcher.generation == 8)
        #expect(catcher.shown == shown)
    }

    @Test(
        "every hand-off step round-trips, carrying a code only when it failed",
        arguments: [
            ClipboardDragHandOffStep.armed, .targeted, .caught,
            .failed(.dragTakeStale, message: "the press is over"),
            .failed(nil, message: ""),
        ])
    func handOffRoundTrips(step: ClipboardDragHandOffStep) throws {
        let decoded = try roundTrip(.dragHandOff(generation: 6, step: step))
        guard case .dragHandOff(let handOff) = decoded.payload else {
            Issue.record("Expected a drag hand-off payload")
            return
        }
        #expect(handOff.generation == 6)
        #expect(ClipboardDragHandOffStep(handOff) == step)
        if case .failed(let code?, _) = step {
            #expect(handOff.code == code.rawValue)
        } else {
            #expect(handOff.code.isEmpty)
        }
    }

    @Test("folder sizes round-trip their generation and every folder's size by index")
    func sizesRoundTrip() throws {
        let decoded = try roundTrip(.dragSizes(generation: 8, folderByteCounts: [1: 4_096, 3: 0]))
        #expect(decoded.protocolVersion == 1)
        guard case .dragSizes(let sizes) = decoded.payload else {
            Issue.record("Expected a drag sizes payload")
            return
        }
        #expect(sizes.generation == 8)
        #expect(sizes.folderByteCounts == [1: 4_096, 3: 0])
    }

    @Test("a stage this build does not define reads as a failure, never as a step to act on")
    func unknownStageIsAFailure() {
        var unspecified = Kernova_V1_DragHandOff()
        unspecified.stage = .unspecified
        var unrecognized = Kernova_V1_DragHandOff()
        unrecognized.stage = .UNRECOGNIZED(99)
        unrecognized.code = "clipboard.drag.who.knows"

        #expect(ClipboardDragHandOffStep(unspecified) == .failed(nil, message: ""))
        #expect(ClipboardDragHandOffStep(unrecognized) == .failed(nil, message: ""))
    }

    @Test("the drag payloads occupy the field numbers the proto reserves for them")
    func usesTheReservedFieldNumbers() throws {
        // A renumbering would decode as an unknown field on a peer built from
        // the previous proto — silently, which is what this pins.
        var offer = Frame()
        offer.dragOffer = Kernova_V1_DragOffer()
        var complete = Frame()
        complete.dragComplete = Kernova_V1_DragComplete()
        var release = Frame()
        release.dragRelease = Kernova_V1_DragRelease()
        var take = Frame()
        take.dragTake = Kernova_V1_DragTake()
        var handOff = Frame()
        handOff.dragHandOff = Kernova_V1_DragHandOff()
        var catcher = Frame()
        catcher.dragCatcher = Kernova_V1_DragCatcher()
        var sizes = Frame()
        sizes.dragSizes = Kernova_V1_DragSizes()

        // Fields 43–49 with wire type 2 encode as the tag byte pairs below.
        #expect(Array(try offer.serializedData()).prefix(2) == [0xDA, 0x02])
        #expect(Array(try complete.serializedData()).prefix(2) == [0xE2, 0x02])
        #expect(Array(try release.serializedData()).prefix(2) == [0xEA, 0x02])
        #expect(Array(try take.serializedData()).prefix(2) == [0xF2, 0x02])
        #expect(Array(try handOff.serializedData()).prefix(2) == [0xFA, 0x02])
        #expect(Array(try catcher.serializedData()).prefix(2) == [0x82, 0x03])
        #expect(Array(try sizes.serializedData()).prefix(2) == [0x8A, 0x03])
    }

    @Test("every drag frame on the control channel classifies as wrong port")
    func dragFramesAreWrongPortOnTheControlChannel() {
        let frames: [Frame] = [
            .dragOffer(generation: 1, reps: []), .dragComplete(generation: 1),
            .dragRelease(generation: 1), .dragTake(generation: 1),
            .dragHandOff(generation: 1, step: .armed), .dragCatcher(generation: 1, shown: true),
            .dragSizes(generation: 1, folderByteCounts: [:]),
        ]
        for frame in frames {
            #expect(ControlChannelInbound.classify(frame) == .wrongPort)
        }
    }
}
