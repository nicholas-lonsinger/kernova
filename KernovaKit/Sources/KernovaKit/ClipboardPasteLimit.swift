import Foundation

/// The ceiling on the total of one paste's file representations, and the ladder
/// of values a user may select for it.
///
/// The cap is a **timeout budget**, not a bandwidth or memory guard: a promised
/// file's bytes pull synchronously inside the consumer's `provideData` callback,
/// which Finder abandons after ~60 s (generic apps after ~120 s). Both ends of
/// the wire enforce the same figure, pushed host→guest in `PolicyUpdate`.
public enum ClipboardPasteLimit {
    /// Largest total a paste's file reps may sum to when the user has expressed
    /// no preference: 2 GiB.
    ///
    /// At the measured 366–415 MiB/s app-stack throughput
    /// (docs/research/2026-07-13-vsock-transport-throughput.md), 2 GiB streams in
    /// ~6 s — over 4× margin under the tighter deadline for a folder's
    /// request-time archive pass, the staging write, and the extract. The cap is
    /// compared against the total of the offer's reps that serve
    /// `public.file-url` — every promisable rep carrying a filename, image files
    /// included — all-or-nothing per paste.
    public static let defaultBytes = 2 * 1024 * 1024 * 1024

    /// Every ceiling the user may select, ascending: 512 MiB through 16 GiB.
    ///
    /// The stops above `defaultBytes` trade the deadline margin for reach, which
    /// `estimatedStreamSeconds(_:)` is what makes legible at the point of choice.
    public static let choices = [
        512 * 1024 * 1024,
        1 * 1024 * 1024 * 1024,
        defaultBytes,
        4 * 1024 * 1024 * 1024,
        8 * 1024 * 1024 * 1024,
        16 * 1024 * 1024 * 1024,
    ]

    /// The lower of the two measured app-stack throughputs, in bytes per second:
    /// 366 MiB/s guest→host
    /// (docs/research/2026-07-13-vsock-transport-throughput.md).
    ///
    /// Estimates read from the slower direction so the figure shown to the user
    /// is the one either direction can meet.
    public static let measuredThroughputBytesPerSecond = 366 * 1024 * 1024

    /// A stored ceiling resolved onto the offered ladder: `nil` — no preference
    /// — and any value that is not an offered stop both land on the nearest one.
    ///
    /// Nothing outside `choices` may reach an enforcement point: a value between
    /// stops has no derivation behind it, and one above the top stop is a
    /// ceiling no paste could honor.
    public static func resolve(_ bytes: Int?) -> Int {
        guard let bytes else { return defaultBytes }
        guard let nearest = choices.min(by: { abs($0 - bytes) < abs($1 - bytes) }) else {
            return defaultBytes
        }
        return nearest
    }

    /// The ceiling a received `PolicyUpdate.clipboard_max_paste_bytes` selects.
    ///
    /// `0` is the field's unset value, not a real ceiling of zero — reading it
    /// literally would refuse every paste. A host that predates the field, or one
    /// that deliberately sends nothing, leaves the receiver on its own default.
    public static func fromPolicy(_ pushed: UInt64) -> Int {
        pushed == 0 ? defaultBytes : Int(clamping: pushed)
    }

    /// How a ceiling reads in user-facing copy, e.g. "2 GB".
    ///
    /// Every surface that names the limit — the Settings pane, the host window's
    /// messages, the Copy-to-Mac refusal, the guest agent's menu line — builds
    /// its sentence from this, so one selection moves the figure everywhere at
    /// once. Rendered in binary units, matching how Finder reports the same
    /// count.
    public static func displayLimit(_ bytes: Int) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        let rounded = (value * 10).rounded() / 10
        let number =
            rounded == rounded.rounded()
            ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "\(number) \(units[unitIndex])"
    }

    /// How long `bytes` takes to stream at the measured throughput, rounded to a
    /// whole second (at least 1).
    ///
    /// Transport time only — a folder's archive and extract passes are on top,
    /// which is what the copy quoting this has to say.
    public static func estimatedStreamSeconds(_ bytes: Int) -> Int {
        let seconds = Double(bytes) / Double(measuredThroughputBytesPerSecond)
        return max(1, Int(seconds.rounded()))
    }
}
