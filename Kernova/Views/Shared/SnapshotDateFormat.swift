import Foundation

/// The one rendering of a snapshot's capture date — the settings row, the
/// revert submenu, the revert confirmation, and Get Info all read it.
enum SnapshotDateFormat {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        // Recent captures are the ones a user is placing in their own day, so
        // they read "Today at 9:42 AM"; older ones fall back to the date.
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
