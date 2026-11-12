#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#endif

/// Where a command-line mode writes its answer and its complaints: the one way to the process's standard
/// output and standard error.
public enum Console {
    /// The two streams written to, each handed whole lines.
    public struct Streams: Sendable {
        let out: @Sendable (String) -> Void
        let err: @Sendable (String) -> Void

        /// Streams that hand standard output's lines to `out` and standard error's to `err`.
        public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void) {
            self.out = out
            self.err = err
        }

        /// The process's standard output and standard error, written unbuffered, so each line is out before
        /// the call returns.
        public static let standard = Streams(
            out: { Console.writeAll($0, to: 1) },
            err: { Console.writeAll($0, to: 2) })
    }

    /// Where this task's writes go: the process's own streams, unless a caller bound others.
    @TaskLocal public static var streams = Streams.standard

    /// Writes `text` and a newline to standard output; an empty string writes nothing, so a listing with no
    /// rows produces no blank line.
    public static func out(_ text: String) {
        guard !text.isEmpty else { return }
        streams.out(text + "\n")
    }

    /// Writes `text` and a newline to standard error, where what is not the answer goes; an empty string
    /// writes nothing.
    public static func notice(_ text: String) {
        guard !text.isEmpty else { return }
        streams.err(text + "\n")
    }

    /// Writes `text` to `descriptor`, resuming after a short write and, where the platform has it, an
    /// interrupted one; what the descriptor refuses is dropped, as there is nowhere left to report it.
    private static func writeAll(_ text: String, to descriptor: Int32) {
        var text = text
        text.withUTF8 { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                #if canImport(ucrt)
                let written = Int(_write(descriptor, base + offset, UInt32(bytes.count - offset)))
                guard written > 0 else { return }
                #else
                let written = write(descriptor, base + offset, bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                #endif
                offset += written
            }
        }
    }
}
