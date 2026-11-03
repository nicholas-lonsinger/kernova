#if canImport(Darwin) || os(Linux)
import KernovaAgentCore
import KernovaWire

/// One payload format's writer: it lands a payload of its ``format`` in a slot, as an install lands the payload
/// it carries and as an update lands what it pulls.
///
/// The lander only writes and publishes. The core reads or receives every byte, hashes them — a payload's
/// SHA-256 is the installed agent's identity — and checks an update's size and hash against its manifest
/// before the landing publishes.
public protocol PayloadLander: Sendable {
    /// The format it lands, which the peer advertises as the one it installs.
    var format: PayloadFormat { get }

    /// Lands the install's payload, read from `payload` to its end, as `name` in `slot`, every file and
    /// directory it makes handed to the slot's owner (``InstallDirectory``).
    func install(_ payload: InstallPayloadReader, as name: String, in slot: InstallDirectory) throws(Installer.Failure)

    /// Begins landing an update in `slot` of `root`. What the slot holds stays until the landing publishes.
    func beginUpdate(in slot: String, of root: SlotRoot) throws(SlotRoot.Failure) -> any PayloadLanding
}

/// One update payload, landing in a slot. The installer calls ``publish()`` or ``discard()`` once, and nothing
/// after it.
public protocol PayloadLanding: Sendable {
    /// Writes the payload's next bytes, all of them, or throws.
    func write(_ bytes: UnsafeRawBufferPointer) throws(SlotRoot.Failure)

    /// Makes the bytes written — the whole payload, its size and SHA-256 verified — the slot's content, once
    /// whatever check the format has of its own passes. On refusal it removes what it wrote.
    func publish() throws(PayloadRefusal)

    /// Removes what it wrote, unpublished.
    func discard()
}

/// Why an update payload was not installed.
public struct PayloadRefusal: Error, Sendable {
    /// What the peer reports.
    public var code: ErrorCode
    /// What failed, for the log and the report's debug detail.
    public var detail: String
    /// The failed call's errno; 0 when no call failed.
    public var errno: Int32
    /// The payload itself is at fault, so the install records it as rejected; false when the install failed
    /// on its own, as a full disk fails it.
    public var rejectsPayload: Bool

    /// A refusal reporting `code`, `detail` saying what failed and `errno` the call's number.
    public init(_ code: ErrorCode, _ detail: String, errno: Int32 = 0, rejectsPayload: Bool = true) {
        self.code = code
        self.detail = detail
        self.errno = errno
        self.rejectsPayload = rejectsPayload
    }

    /// The refusal as the peer reports it.
    var error: WireError { WireError(code, posixErrno: errno, debugDetail: detail) }
}
#endif
