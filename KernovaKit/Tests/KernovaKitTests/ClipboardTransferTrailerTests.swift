import Darwin
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The two detectors a data connection has: the 33-byte trailer that says how a
/// payload ended, and the reader that holds those bytes back so the payload the
/// consumer sees ends exactly where the sender ended it.
@Suite("ClipboardTransferTrailer and ClipboardPayloadReader", .admissionGated)
struct ClipboardTransferTrailerTests {
    /// A well-sized trailer whose body is all zeroes, so a test can write one
    /// the encoder would never produce.
    private func trailerBytes(kind: UInt8) -> Data {
        var bytes = Data(count: ClipboardTransferTrailer.byteCount)
        bytes[0] = kind
        return bytes
    }

    /// A descriptor carrying `bytes` and then end of stream.
    ///
    /// The writing end runs on a thread of its own, so a payload past the socket
    /// buffer parks that thread rather than the test's.
    private func stream(_ bytes: Data) throws -> Int32 {
        try dialToPeer { far in
            try? writeTransferBytes(fd: far, bytes)
            Darwin.close(far)
        }
    }

    /// Everything the reader releases, in the blocks it releases it in.
    private func readAll(_ reader: ClipboardPayloadReader) throws -> Data {
        var collected = Data()
        var block = [UInt8](repeating: 0, count: 4096)
        while true {
            let got = try block.withUnsafeMutableBytes { raw in
                try reader.read(into: raw)
            }
            guard got > 0 else { return collected }
            collected.append(contentsOf: block[..<got])
        }
    }

    // MARK: - Parsing

    @Test("a complete trailer round-trips its digest")
    func completeTrailerRoundTrips() throws {
        let digest = sha256(Data("payload".utf8))
        let encoded = ClipboardTransferTrailer(ending: .complete(digest: digest)).encoded

        #expect(encoded.count == ClipboardTransferTrailer.byteCount)
        #expect(ClipboardTransferTrailer.parse(encoded)?.ending == .complete(digest: digest))
    }

    @Test("an abort trailer round-trips its code")
    func abortTrailerRoundTrips() throws {
        let encoded = ClipboardTransferTrailer(ending: .aborted(rawCode: "stall.timeout")).encoded

        #expect(encoded.count == ClipboardTransferTrailer.byteCount)
        #expect(
            ClipboardTransferTrailer.parse(encoded)?.ending == .aborted(rawCode: "stall.timeout"))
    }

    @Test(
        "a kind byte naming neither ending is not a trailer",
        arguments: [UInt8(2), 0x0A, 0x7F, 0xFF])
    func unknownKindByteIsRefused(kind: UInt8) throws {
        #expect(ClipboardTransferTrailer.parse(trailerBytes(kind: kind)) == nil)
    }

    /// An abort with nothing to name is the shape a zero-filled buffer takes:
    /// refusing it is what keeps a truncated stream from reading as a named
    /// abort.
    @Test("an abort trailer with an empty code is not a trailer")
    func emptyAbortCodeIsRefused() throws {
        #expect(ClipboardTransferTrailer.parse(trailerBytes(kind: 1)) == nil)
    }

    @Test("only exactly the trailer's own length parses", arguments: [0, 1, 32, 34])
    func wrongLengthIsRefused(count: Int) throws {
        #expect(ClipboardTransferTrailer.parse(Data(count: count)) == nil)
    }

    /// The spelling is the peer's, and 32 bytes is all the trailer has for it,
    /// so a longer one crosses as its first 32 bytes rather than overrunning.
    @Test("an abort code past 32 bytes is truncated to what the trailer holds")
    func longAbortCodeIsTruncated() throws {
        let code = String(repeating: "z", count: 40)
        let encoded = ClipboardTransferTrailer(ending: .aborted(rawCode: code)).encoded

        #expect(encoded.count == ClipboardTransferTrailer.byteCount)
        #expect(
            ClipboardTransferTrailer.parse(encoded)?.ending
                == .aborted(rawCode: String(repeating: "z", count: 32)))
    }

    // MARK: - Holding the trailer back

    @Test("the reader releases the payload and never a byte of the trailer")
    func readerHoldsTheTrailerBack() throws {
        let payload = patternedBytes(count: 9000, multiplier: 7, offset: 5)
        let trailer = ClipboardTransferTrailer(ending: .complete(digest: sha256(payload)))
        let fd = try stream(payload + trailer.encoded)
        defer { ClipboardDataConnection.end(fd: fd) }
        let released = Box(0)
        let reader = ClipboardPayloadReader(fd: fd, bufferBytes: 1024) { released.value = $0 }

        let taken = try readAll(reader)

        #expect(taken == payload)
        #expect(reader.byteCount == payload.count)
        #expect(released.value == payload.count)
        // The only corruption detector this transport has, taken over exactly
        // the bytes the consumer got (docs/CLIPBOARD.md §7).
        #expect(reader.digest() == sha256(payload))
        #expect(try reader.trailer() == trailer)
    }

    @Test("a stream ending short of the payload it promised is a truncation")
    func readExactlyPastTheStreamIsTruncated() throws {
        let payload = patternedBytes(count: 50, multiplier: 3, offset: 1)
        let trailer = ClipboardTransferTrailer(ending: .complete(digest: sha256(payload)))
        let fd = try stream(payload + trailer.encoded)
        defer { ClipboardDataConnection.end(fd: fd) }
        let reader = ClipboardPayloadReader(fd: fd)

        #expect(throws: ClipboardDataConnectionError.truncated) {
            _ = try reader.readExactly(payload.count + 1)
        }
    }

    @Test("a stream ending without a whole trailer is a truncation")
    func shortStreamHasNoTrailer() throws {
        let fd = try stream(Data(count: ClipboardTransferTrailer.byteCount - 1))
        defer { ClipboardDataConnection.end(fd: fd) }
        let reader = ClipboardPayloadReader(fd: fd)

        #expect(throws: ClipboardDataConnectionError.truncated) { _ = try reader.trailer() }
    }

    // MARK: - Draining a finished payload

    @Test("a drain inside its allowance leaves the trailer readable")
    func drainWithinAllowanceKeepsTheTrailer() throws {
        let surplus = patternedBytes(count: 256, multiplier: 11, offset: 2)
        let trailer = ClipboardTransferTrailer(ending: .aborted(rawCode: "size.overrun"))
        let fd = try stream(surplus + trailer.encoded)
        defer { ClipboardDataConnection.end(fd: fd) }
        let reader = ClipboardPayloadReader(fd: fd)

        try reader.drain(allowance: surplus.count)

        #expect(try reader.trailer() == trailer)
    }

    @Test("a peer streaming past its allowance is a trailing surplus")
    func drainPastAllowanceIsRefused() throws {
        let surplus = patternedBytes(count: 256, multiplier: 11, offset: 2)
        let trailer = ClipboardTransferTrailer(ending: .complete(digest: sha256(surplus)))
        let fd = try stream(surplus + trailer.encoded)
        defer { ClipboardDataConnection.end(fd: fd) }
        let reader = ClipboardPayloadReader(fd: fd, bufferBytes: 64)

        #expect(throws: ClipboardDataConnectionError.trailingSurplus) {
            try reader.drain(allowance: surplus.count - 1)
        }
    }
}
