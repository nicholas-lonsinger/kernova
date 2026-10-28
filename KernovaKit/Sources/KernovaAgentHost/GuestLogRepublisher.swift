import KernovaLogging

/// Republishes a guest agent's log records into the host's log, behind a public prefix naming where each
/// came from, so they read beside the host's own records.
public struct GuestLogRepublisher: Sendable {
    private let logger: KernovaLogger

    /// Republishes under subsystem `app.kernova.guest`, with the VM's `label` as the category.
    public init(vmLabel label: String) {
        self.init(logger: KernovaLogger(subsystem: "app.kernova.guest", category: label))
    }

    /// Republishes through `logger`.
    public init(logger: KernovaLogger) {
        self.logger = logger
    }

    /// Logs `segments` at `level` behind the public `prefix`; each segment keeps the privacy the guest
    /// gave it.
    public func republish(_ level: KernovaLogLevel, prefix: String, _ segments: [LogSegment]) {
        logger.log(level, LogMessage(segments: [LogSegment(text: prefix, isPrivate: false)] + segments))
    }
}
