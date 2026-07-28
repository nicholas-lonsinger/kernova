import Foundation
import Virtualization

/// An error that can name a shell command the user can run to resolve it.
///
/// Lets the presentation layer offer the command for copying without knowing
/// which error type produced it.
protocol CommandSuggestingError {
    /// The command to offer, or `nil` when this error has no such remedy.
    var suggestedCommand: String? { get }
}

/// Translates `VZError.Code.invalidDiskImage` into a message the user can act
/// on, and builds the command that converts a rejected image.
///
/// `VZDiskImageStorageDeviceAttachment(url:readOnly:)` enforces exactly one
/// thing: the file's size is a multiple of 512 bytes. Any 512-aligned file is
/// accepted — random bytes and compressed disk images included — and everything
/// else fails with `invalidDiskImage` ("The disk image format is not
/// recognized"), whatever the actual contents. Compressed `.dmg` files are the
/// common casualty because their size is arbitrary; converting to ASIF or RAW
/// yields both an aligned size and contents the guest can read.
enum DiskImageFormatGuidance {
    /// `true` when `error` is Virtualization's invalid-disk-image error.
    static func isInvalidDiskImage(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == VZError.errorDomain
            && VZError.Code(rawValue: nsError.code) == .invalidDiskImage
    }

    /// Lead-in shown above the copyable conversion command in an alert.
    static let convertPrompt = "To convert it, run this in Terminal:"

    /// Why an attachment couldn't be opened, worded for the cause.
    ///
    /// `subject` names the item as the sentence's object — `"storage disk
    /// 'Data'"`.
    static func attachFailureMessage(
        subject: String, path: String, underlying: any Error
    ) -> String {
        guard isInvalidDiskImage(underlying) else {
            return
                "Couldn't open \(subject) at \(path). The file may have been moved or replaced, or Kernova may no longer have permission to read it. (\(underlying.localizedDescription))"
        }
        return
            "Couldn't open \(subject) at \(path). Virtualization reads only raw sector images, whose size must be a multiple of 512 bytes; most compressed disk images, including .dmg files, aren't. Convert it to ASIF — the format Kernova uses for its own disks."
    }

    /// The `diskutil` command converting the image at `path` to an ASIF copy
    /// beside it, or `nil` when `underlying` is not the invalid-disk-image error.
    static func suggestedCommand(forPath path: String, underlying: any Error) -> String? {
        guard isInvalidDiskImage(underlying) else { return nil }
        let destination =
            URL(fileURLWithPath: path)
            .deletingPathExtension()
            .appendingPathExtension("asif")
            .path(percentEncoded: false)
        return
            "diskutil image create from --format ASIF \(shellQuoted(path)) \(shellQuoted(destination))"
    }

    /// Wraps `value` in single quotes for pasting into a POSIX shell, ending and
    /// reopening the quoted run around each embedded quote.
    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
