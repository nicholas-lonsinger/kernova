import Testing

@testable import KernovaKit

@Suite("ClipboardFileProviderReminder")
struct ClipboardFileProviderReminderTests {
    // MARK: - shouldShowReminder

    @Test("shows only for .needsEnabling and not dismissed")
    func showsOnlyWhenNeedsEnablingAndNotDismissed() {
        #expect(
            ClipboardFileProviderReminder.shouldShowReminder(
                availability: .needsEnabling, dismissed: false) == true)
        #expect(
            ClipboardFileProviderReminder.shouldShowReminder(
                availability: .needsEnabling, dismissed: true) == false)
    }

    @Test("never shows for .inactive, .ready, or .unavailable, dismissed or not")
    func neverShowsForOtherAvailabilities() {
        for availability: FileProviderAvailability in [.inactive, .ready, .unavailable] {
            #expect(
                ClipboardFileProviderReminder.shouldShowReminder(
                    availability: availability, dismissed: false) == false)
            #expect(
                ClipboardFileProviderReminder.shouldShowReminder(
                    availability: availability, dismissed: true) == false)
        }
    }

    // MARK: - Degraded-mode summaries

    @Test("hostDegradedSummary mentions files, not text/images, as limited")
    func hostSummaryMentionsFiles() {
        let summary = ClipboardFileProviderReminder.hostDegradedSummary()
        #expect(summary.contains("Text and images copy normally"))
        #expect(summary.contains("File Provider"))
    }

    @Test("guestDegradedSummary makes no size promise")
    func guestSummaryMakesNoSizePromise() {
        let summary = ClipboardFileProviderReminder.guestDegradedSummary()
        #expect(summary.contains("Text and images paste normally"))
        #expect(summary.contains("File Provider"))
        // #561: the host→guest direction has no deadline-safe size cap yet, so
        // the guest-side copy must never cite a byte figure a user could rely on.
        #expect(!summary.contains("MB"))
        #expect(!summary.contains("MiB"))
    }

    @Test("host and guest summaries are distinct")
    func summariesDiffer() {
        #expect(
            ClipboardFileProviderReminder.hostDegradedSummary()
                != ClipboardFileProviderReminder.guestDegradedSummary())
    }
}
