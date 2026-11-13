#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Why a clipboard, drop or drag transfer failed, as the side that failed
/// reports it.
public enum ClipboardErrorCode: Sendable {
    /// The offer's paste-bound reps exceed the deadline-safe cap, so the guest
    /// refused the paste pull.
    case pasteTooLarge

    /// The paste failed for a reason with no more specific code.
    case pasteFailed

    /// The guest has no room to write a dropped file into its Downloads folder.
    case dropDiskFull

    /// The guest could not write into its Downloads folder — the guest user has
    /// not granted the agent access to it.
    case dropDownloadsDenied

    /// A dropped file did not reach the guest's Downloads folder, for a reason
    /// with no more specific code.
    case dropFailed

    /// A dropped item's bytes arrived but the guest could not unpack them.
    case dropUnpackFailed

    /// A promised item of a guest drag will never have bytes to pull: its
    /// source failed to write it.
    case dragItemUnavailable
}
