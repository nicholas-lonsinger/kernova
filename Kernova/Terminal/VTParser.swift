import Foundation

/// Receives the structured events a `VTParser` decodes from a raw byte stream.
///
/// The parser is a pure DFA that knows nothing about grids or rendering — it
/// only classifies bytes and emits these callbacks. `TerminalEmulator` conforms
/// to this protocol and applies the events to its cell buffers; tests conform a
/// lightweight recorder to assert the exact dispatch sequence.
///
/// `@MainActor` because the production conformer (`TerminalEmulator`) mutates
/// main-actor state; the parser invokes these synchronously from `feed`.
@MainActor
protocol TerminalPerformer: AnyObject {
    /// A printable character (already UTF-8 decoded) should be written at the cursor.
    func print(_ scalar: UnicodeScalar)
    /// A C0 control byte (`< 0x20`) should be executed (LF, CR, BS, HT, BEL, …).
    func execute(_ control: UInt8)
    /// A complete CSI sequence: `ESC [ <prefix> <params> <intermediates> <final>`.
    /// `prefix` is a private marker byte (`?`, `>`, `<`, `=`) when present.
    func csiDispatch(prefix: UInt8?, params: [Int], intermediates: [UInt8], final: UInt8)
    /// A complete two/three-byte escape sequence: `ESC <intermediates> <final>`.
    func escDispatch(intermediates: [UInt8], final: UInt8)
    /// A complete OSC string payload (the bytes between `ESC ]` and its `BEL`/`ST` terminator).
    func oscDispatch(_ data: [UInt8])
}

/// An ECMA-48 / DEC escape-sequence parser modeled on Paul Williams' VT500
/// state machine (https://vt100.net/emu/dec_ansi_parser).
///
/// Consumes raw guest bytes one at a time and emits `TerminalPerformer` events.
/// Built to tolerate arbitrary/adversarial input: it never buffers the whole
/// stream, bounds every accumulator, and always resyncs to a sane state.
///
/// UTF-8 is decoded incrementally in the ground state only (the escape grammar
/// is pure 7-bit ASCII); partial multibyte sequences are carried across `feed`
/// calls so a codepoint split over a pipe-read boundary is never dropped. C1
/// controls (0x80–0x9F) are intentionally treated as UTF-8 bytes, not controls,
/// since Linux serial consoles run in UTF-8 mode and use 7-bit escapes.
struct VTParser {
    // MARK: Robustness caps

    /// Max stored CSI/DCS numeric parameters; further params are scanned but discarded.
    static let maxParams = 16
    /// Saturating ceiling for a single parameter value.
    static let maxParamValue = 65535
    /// Max intermediate bytes before a sequence is abandoned.
    static let maxIntermediates = 2
    /// Max bytes buffered for an OSC string before further bytes are discarded.
    static let maxOSCLength = 4096

    // MARK: State

    private enum State {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case oscString
        case dcsPassthrough  // covers DCS entry/param/intermediate/data — swallowed wholesale
        case stringIgnore  // SOS / PM / APC — consumed until ST
    }

    private var state: State = .ground

    // CSI / escape accumulators
    private var params: [Int] = []
    private var currentParam: Int?
    private var prefix: UInt8?
    private var intermediates: [UInt8] = []
    private var paramsFull = false

    // OSC accumulator
    private var oscBuffer: [UInt8] = []
    private var oscOverflowed = false

    // Incremental UTF-8 decoder (ground state only)
    private var utf8Buffer: [UInt8] = []
    private var utf8Remaining = 0

    private static let replacement: UnicodeScalar = "\u{FFFD}"

    // MARK: Feed

    /// Feed raw bytes from the pipe, dispatching decoded events to `performer`.
    @MainActor
    mutating func feed<P: TerminalPerformer>(_ data: Data, to performer: P) {
        for byte in data {
            advance(byte, performer)
        }
    }

    @MainActor
    private mutating func advance<P: TerminalPerformer>(_ byte: UInt8, _ performer: P) {
        // --- UTF-8 continuation (ground state only) ---
        if state == .ground, utf8Remaining > 0 {
            if byte & 0xC0 == 0x80 {
                utf8Buffer.append(byte)
                utf8Remaining -= 1
                if utf8Remaining == 0 { emitUTF8(performer) }
                return
            }
            // Incomplete sequence interrupted — emit replacement, then reprocess `byte`.
            performer.print(Self.replacement)
            utf8Buffer.removeAll(keepingCapacity: true)
            utf8Remaining = 0
        }

        // --- Universal aborts (any state) ---
        switch byte {
        case 0x18, 0x1A:  // CAN, SUB — abort any sequence back to ground
            terminateStringIfNeeded(performer)
            state = .ground
            clear()
            return
        case 0x1B:  // ESC — terminates strings, starts a fresh escape
            terminateStringIfNeeded(performer)
            state = .escape
            clear()
            return
        default:
            break
        }

        // --- C0 controls (other than the aborts above) ---
        if byte < 0x20 || byte == 0x7F {
            switch state {
            case .oscString:
                if byte == 0x07 {  // BEL terminates OSC (xterm extension)
                    performer.oscDispatch(oscBuffer)
                    state = .ground
                    clear()
                }
            // others ignored inside OSC
            case .dcsPassthrough, .stringIgnore, .csiIgnore:
                break  // ignore controls inside swallowed strings
            default:
                if byte != 0x7F { performer.execute(byte) }  // DEL ignored
            }
            return
        }

        // --- Printable / sequence bytes by state ---
        switch state {
        case .ground:
            groundPrintable(byte, performer)

        case .escape:
            escapeByte(byte, performer)

        case .escapeIntermediate:
            if (0x20...0x2F).contains(byte) {
                appendIntermediate(byte)
            } else {  // 0x30...0x7E final
                performer.escDispatch(intermediates: intermediates, final: byte)
                state = .ground
                clear()
            }

        case .csiEntry:
            csiEntryByte(byte, performer)

        case .csiParam:
            csiParamByte(byte, performer)

        case .csiIntermediate:
            csiIntermediateByte(byte, performer)

        case .csiIgnore:
            if (0x40...0x7E).contains(byte) { state = .ground; clear() }
        // else keep ignoring

        case .oscString:
            appendOSC(byte)

        case .dcsPassthrough:
            break  // data bytes swallowed; terminated by ESC/ST handled above

        case .stringIgnore:
            break  // swallowed; terminated by ESC/ST handled above
        }
    }

    // MARK: Ground (UTF-8 assembly)

    @MainActor
    private mutating func groundPrintable<P: TerminalPerformer>(_ byte: UInt8, _ performer: P) {
        if byte < 0x80 {
            performer.print(UnicodeScalar(byte))
        } else if byte & 0xE0 == 0xC0 {
            utf8Buffer = [byte]
            utf8Remaining = 1
        } else if byte & 0xF0 == 0xE0 {
            utf8Buffer = [byte]
            utf8Remaining = 2
        } else if byte & 0xF8 == 0xF0 {
            utf8Buffer = [byte]
            utf8Remaining = 3
        } else {
            // Stray continuation byte or invalid lead.
            performer.print(Self.replacement)
        }
    }

    @MainActor
    private mutating func emitUTF8<P: TerminalPerformer>(_ performer: P) {
        if let scalar = String(bytes: utf8Buffer, encoding: .utf8)?.unicodeScalars.first {
            performer.print(scalar)
        } else {
            performer.print(Self.replacement)
        }
        utf8Buffer.removeAll(keepingCapacity: true)
        utf8Remaining = 0
    }

    // MARK: Escape

    @MainActor
    private mutating func escapeByte<P: TerminalPerformer>(_ byte: UInt8, _ performer: P) {
        switch byte {
        case 0x5B:  // [
            state = .csiEntry
            clear()
        case 0x5D:  // ]
            state = .oscString
            clear()
        case 0x50:  // P — DCS
            state = .dcsPassthrough
            clear()
        case 0x58, 0x5E, 0x5F:  // X (SOS), ^ (PM), _ (APC)
            state = .stringIgnore
            clear()
        case 0x20...0x2F:  // intermediate
            appendIntermediate(byte)
            state = .escapeIntermediate
        default:  // 0x30...0x7E final
            performer.escDispatch(intermediates: intermediates, final: byte)
            state = .ground
            clear()
        }
    }

    // MARK: CSI

    @MainActor
    private mutating func csiEntryByte<P: TerminalPerformer>(_ byte: UInt8, _ performer: P) {
        switch byte {
        case 0x30...0x39:  // digit
            pushDigit(byte)
            state = .csiParam
        case 0x3A, 0x3B:  // : or ; — parameter separator
            pushSeparator()
            state = .csiParam
        case 0x3C...0x3F:  // < = > ? — private prefix marker
            prefix = byte
            state = .csiParam
        case 0x20...0x2F:  // intermediate
            appendIntermediate(byte)
            state = .csiIntermediate
        default:  // 0x40...0x7E final
            dispatchCSI(final: byte, performer)
        }
    }

    @MainActor
    private mutating func csiParamByte<P: TerminalPerformer>(_ byte: UInt8, _ performer: P) {
        switch byte {
        case 0x30...0x39:
            pushDigit(byte)
        case 0x3A, 0x3B:
            pushSeparator()
        case 0x3C...0x3F:  // private markers only valid at entry — abandon
            state = .csiIgnore
        case 0x20...0x2F:
            appendIntermediate(byte)
            state = .csiIntermediate
        default:  // final
            dispatchCSI(final: byte, performer)
        }
    }

    @MainActor
    private mutating func csiIntermediateByte<P: TerminalPerformer>(_ byte: UInt8, _ performer: P) {
        switch byte {
        case 0x20...0x2F:
            appendIntermediate(byte)
        case 0x30...0x3F:  // params/markers after intermediates are invalid
            state = .csiIgnore
        default:  // final
            dispatchCSI(final: byte, performer)
        }
    }

    @MainActor
    private mutating func dispatchCSI<P: TerminalPerformer>(final: UInt8, _ performer: P) {
        finishParams()
        performer.csiDispatch(
            prefix: prefix, params: params, intermediates: intermediates, final: final)
        state = .ground
        clear()
    }

    // MARK: Accumulator helpers

    private mutating func pushDigit(_ byte: UInt8) {
        guard !paramsFull else { return }
        let digit = Int(byte - 0x30)
        currentParam = min((currentParam ?? 0) * 10 + digit, Self.maxParamValue)
    }

    private mutating func pushSeparator() {
        guard !paramsFull else { return }
        if params.count >= Self.maxParams {
            paramsFull = true
            return
        }
        params.append(currentParam ?? 0)
        currentParam = nil
    }

    private mutating func finishParams() {
        if let value = currentParam, params.count < Self.maxParams {
            params.append(value)
        }
        currentParam = nil
    }

    private mutating func appendIntermediate(_ byte: UInt8) {
        if intermediates.count >= Self.maxIntermediates {
            state = .csiIgnore
            return
        }
        intermediates.append(byte)
    }

    private mutating func appendOSC(_ byte: UInt8) {
        if oscBuffer.count >= Self.maxOSCLength {
            oscOverflowed = true
            return  // keep scanning for the terminator, but stop storing
        }
        oscBuffer.append(byte)
    }

    @MainActor
    private mutating func terminateStringIfNeeded<P: TerminalPerformer>(_ performer: P) {
        if state == .oscString {
            performer.oscDispatch(oscBuffer)
        }
        // DCS / SOS / PM / APC are swallowed — nothing to dispatch.
    }

    private mutating func clear() {
        params.removeAll(keepingCapacity: true)
        currentParam = nil
        prefix = nil
        intermediates.removeAll(keepingCapacity: true)
        paramsFull = false
        oscBuffer.removeAll(keepingCapacity: true)
        oscOverflowed = false
    }
}
