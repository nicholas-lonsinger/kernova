import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaUI

/// Verifies the guest-setup download-progress subtitle holds a stable
/// horizontal position as it updates (#555).
///
/// The subtitle is two center-aligned labels, so any change in a line's
/// *rendered width* re-centers it and reads as horizontal jitter. These tests
/// measure the actual rendered width of each line in the labels' own font and
/// assert the structural invariants that keep it still — rather than counting
/// characters, which a proportional unit suffix (KB vs MB) would defeat.
@MainActor
@Suite("Guest setup subtitle width stability", .caseScoped)
struct GuestSetupSubtitleTests {
    /// The exact font `GuestSetupProgressViewController` gives its detail labels.
    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)

    /// The verbs the macOS install descriptor gives its two steps — the widest
    /// wording the subtitle ships with.
    private static let downloadVerb = GuestSetupDescriptor.macOSInstall.copy(for: .download)
        .detailVerb

    private func width(_ line: String) -> CGFloat {
        NSAttributedString(string: line, attributes: [.font: Self.font]).size().width
    }

    /// The subtitle lines for an estimate of `etaSeconds` at `bytesPerSecond`.
    private func downloadLines(etaSeconds: Int, bytesPerSecond: Double) -> [String] {
        let remaining = Int64((Double(etaSeconds) * bytesPerSecond).rounded())
        let progress = SetupStepProgress.download(
            DownloadProgress(
                bytesWritten: 0, totalBytes: remaining, bytesPerSecond: bytesPerSecond))
        return [
            GuestSetupProgressViewController.detailLine1(for: progress, verb: Self.downloadVerb),
            GuestSetupProgressViewController.detailLine2(for: progress),
        ].compactMap { $0 }
    }

    /// ETA values spanning every unit boundary the H:MM:SS clock can cross.
    private let etaBoundaries = [9, 10, 59, 60, 90, 3_599, 3_600, 35_999, 36_000, 359_000]
    /// One speed per display regime: KB/s, MB/s, GB/s.
    private let regimeSpeeds: [Double] = [500_000, 20_000_000, 2_000_000_000]

    // A width move of half a point is imperceptible; a real regression from an
    // un-normalized field jumps by several points.
    private let tolerance: CGFloat = 0.5

    @Test("Line 2 holds a constant width as the ETA crosses unit boundaries, within each speed regime")
    func line2StableWithinRegime() {
        for speed in regimeSpeeds {
            let widths = etaBoundaries.map {
                width(downloadLines(etaSeconds: $0, bytesPerSecond: speed)[1])
            }
            let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
            #expect(
                spread < tolerance,
                "line 2 width moved by \(spread)pt at \(speed) B/s as the ETA changed")
        }
    }

    @Test("The ETA placeholder keeps line 2 width identical when speed flaps around the 1 KB/s guard")
    func placeholderMatchesNumericWidth() {
        // Just above the guard yields a real estimate; just below yields the
        // placeholder. Both render the same "1.0 KB/s" speed, so line 2 must not
        // move as the speed dips across the guard and back.
        let numeric = GuestSetupProgressViewController.detailLine2(
            for: .download(
                DownloadProgress(bytesWritten: 0, totalBytes: 100_100, bytesPerSecond: 1_001)))
        let placeholder = GuestSetupProgressViewController.detailLine2(
            for: .download(
                DownloadProgress(bytesWritten: 0, totalBytes: 99_900, bytesPerSecond: 999)))
        #expect(numeric != nil)
        #expect(placeholder != nil)
        #expect(abs(width(numeric ?? "") - width(placeholder ?? "")) < tolerance)
    }

    // MARK: - Per-line builders (the labels are refreshed on separate cadences)

    @Test("detailLine2 is nil for the install phase and before the first speed sample")
    func line2NilWhenNotApplicable() {
        #expect(GuestSetupProgressViewController.detailLine2(for: .fraction(0.5)) == nil)
        #expect(
            GuestSetupProgressViewController.detailLine2(
                for: .download(
                    DownloadProgress(bytesWritten: 0, totalBytes: 1_000_000, bytesPerSecond: 0)))
                == nil)
    }
}
