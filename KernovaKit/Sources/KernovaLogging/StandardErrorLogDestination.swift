import Foundation

/// Where a `KernovaLogger` records locally where there is no unified log: one
/// line per record on standard error, which journald files as one entry for a
/// systemd service.
///
/// Each line opens with its level's syslog priority as `<N>`, which journald
/// strips and files as the entry's priority (`SyslogLevelPrefix=`, on by
/// default — systemd.exec(5); the prefixes are sd-daemon(3)'s).
struct StandardErrorLogDestination: Sendable {
    /// The least severe level written. `.debug` is left out, as the unified
    /// log keeps it only while a client streams.
    static let threshold = KernovaLogLevel.info

    private let label: String

    init(subsystem: String, category: String) {
        label = "[\(subsystem):\(category)]"
    }

    /// Whether `level` is at or above `threshold`.
    func records(_ level: KernovaLogLevel) -> Bool {
        level.syslogPriority <= Self.threshold.syslogPriority
    }

    /// Writes the record's `line` in one write; a line standard error refuses
    /// is dropped, as there is nowhere left to report it.
    func emit(_ segments: [LogSegment], at level: KernovaLogLevel) {
        try? FileHandle.standardError.write(contentsOf: Data(line(segments, at: level).utf8))
    }

    /// The record as written: the priority, `[subsystem:category]`, then the
    /// message with each run of private segments as one `<private>`, ending in
    /// a newline. A line break inside it prints as `\n`, `\r` or `\0`, so the
    /// record stays one line.
    func line(_ segments: [LogSegment], at level: KernovaLogLevel) -> String {
        var message = ""
        var inPrivateRun = false
        for segment in segments where !segment.text.isEmpty {
            if !segment.isPrivate {
                message += segment.text
            } else if !inPrivateRun {
                message += "<private>"
            }
            inPrivateRun = segment.isPrivate
        }
        return "<\(level.syslogPriority)>\(Self.oneLine("\(label) \(message)"))\n"
    }

    private static func oneLine(_ text: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": escaped.append(contentsOf: #"\n"#.unicodeScalars)
            case "\r": escaped.append(contentsOf: #"\r"#.unicodeScalars)
            case "\0": escaped.append(contentsOf: #"\0"#.unicodeScalars)
            default: escaped.append(scalar)
            }
        }
        return String(escaped)
    }
}

extension KernovaLogLevel {
    /// The syslog priority a record at this level is filed under: smaller is
    /// more severe.
    var syslogPriority: Int {
        switch self {
        case .debug: 7
        case .info: 6
        case .notice: 5
        case .warning: 4
        case .error: 3
        case .fault: 2
        }
    }
}
