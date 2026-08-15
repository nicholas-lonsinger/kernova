import Testing

@testable import KernovaKit

/// Relations the stream's tuning constants hold to each other.
///
/// Each is a trap a plausible edit springs silently: nothing at runtime reports
/// a default window above the cap acks are clamped to, a chunk too large for the
/// window pacing it, or an extract guard re-checking more coarsely than the
/// margin it defends.
@Suite("ClipboardStreamTuning")
struct ClipboardStreamTuningTests {
    @Test("the default credit window fits inside the cap acks are clamped to")
    func defaultWindowFitsTheCap() {
        // Above the cap the default survives exactly until the first ack, which
        // clamps it back — so a raise reads as landed while nothing changed.
        #expect(ClipboardStreamTuning.defaultWindowBytes <= ClipboardStreamTuning.maxWindowBytes)
    }

    @Test("a chunk fits both the window pacing it and the ceiling receiving it")
    func chunkFitsItsBounds() {
        #expect(
            ClipboardStreamTuning.defaultChunkPayloadSize
                <= ClipboardStreamTuning.defaultWindowBytes)
        #expect(
            ClipboardStreamTuning.defaultChunkPayloadSize <= ClipboardStreamTuning.maxChunkBytes)
    }

    @Test("the extract guard re-checks inside the free-space margin it defends")
    func guardQuantumFitsTheFreeSpaceMargin() {
        #expect(ClipboardStreamTuning.extractPacingBytes <= ClipboardStreamTuning.freeSpaceMargin)
    }
}
