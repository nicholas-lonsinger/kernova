import os

/// A message's segments as the one `os.Logger` record emitted locally: public
/// runs alternating with private runs, each private run its own
/// `%{private}s` argument so `logd` redacts exactly those values and reveals
/// them under the system's private-data setting. Each case's values alternate
/// public, private, public, starting and ending with a public run that may be
/// empty.
///
/// `os.Logger` takes its message only as a literal at the call site, so each
/// case has one static literal in `emit`. Past three private runs, the fourth
/// and later — with the public text between them — fold into the third private
/// argument: the absorbed public text is redacted with it, and revealed with
/// the other private runs under the private-data setting.
enum LocalLogRecord: Equatable {
    case noPrivate(String)
    case onePrivate(String, String, String)
    case twoPrivate(String, String, String, String, String)
    case threePrivate(String, String, String, String, String, String, String)

    private static let maxPrivateRuns = 3

    /// Merges `segments` into runs; an empty segment adds nothing.
    init(segments: [LogSegment]) {
        var publicRuns = [""]
        var privateRuns: [String] = []
        for segment in segments where !segment.text.isEmpty {
            let last = publicRuns.count - 1
            if !segment.isPrivate {
                publicRuns[last] += segment.text
            } else if privateRuns.count == Self.maxPrivateRuns
                || (!privateRuns.isEmpty && publicRuns[last].isEmpty)
            {
                privateRuns[privateRuns.count - 1] += publicRuns[last] + segment.text
                publicRuns[last] = ""
            } else {
                privateRuns.append(segment.text)
                publicRuns.append("")
            }
        }
        let p = publicRuns
        let x = privateRuns
        switch x.count {
        case 0: self = .noPrivate(p[0])
        case 1: self = .onePrivate(p[0], x[0], p[1])
        case 2: self = .twoPrivate(p[0], x[0], p[1], x[1], p[2])
        default:
            self = .threePrivate(p[0], x[0], p[1], x[1], p[2], x[2], p[3])
        }
    }

    func emit(to logger: os.Logger, at type: OSLogType) {
        switch self {
        case .noPrivate(let p0):
            logger.log(level: type, "\(p0, privacy: .public)")
        case .onePrivate(let p0, let x0, let p1):
            logger.log(level: type, "\(p0, privacy: .public)\(x0, privacy: .private)\(p1, privacy: .public)")
        case .twoPrivate(let p0, let x0, let p1, let x1, let p2):
            logger.log(
                level: type,
                "\(p0, privacy: .public)\(x0, privacy: .private)\(p1, privacy: .public)\(x1, privacy: .private)\(p2, privacy: .public)"
            )
        case .threePrivate(let p0, let x0, let p1, let x1, let p2, let x2, let p3):
            logger.log(
                level: type,
                "\(p0, privacy: .public)\(x0, privacy: .private)\(p1, privacy: .public)\(x1, privacy: .private)\(p2, privacy: .public)\(x2, privacy: .private)\(p3, privacy: .public)"
            )
        }
    }
}
