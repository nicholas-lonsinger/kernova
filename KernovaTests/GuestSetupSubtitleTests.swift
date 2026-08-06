import AppKit
import Testing

@testable import Kernova

/// Verifies the guest-setup download-progress subtitle holds a stable
/// horizontal position as it updates (#555).
///
/// The subtitle is one center-aligned wrapping label, so any change in a line's
/// *rendered width* re-centers it and reads as horizontal jitter. These tests
/// measure the actual rendered width of the assembled lines in the label's own
/// font and assert the structural invariants that keep it still — rather than
/// counting characters, which a proportional unit suffix (KB vs MB) would defeat.
@MainActor
@Suite("Guest setup subtitle width stability")
struct GuestSetupSubtitleTests {
    /// The exact font `GuestSetupProgressViewController` gives `detailLabel`.
    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)

    /// The verbs the macOS install descriptor gives its two steps — the widest
    /// wording the subtitle ships with.
    private static let downloadVerb = GuestSetupDescriptor.macOSInstall.copy(for: .download)
        .detailVerb
    private static let installVerb = GuestSetupDescriptor.macOSInstall.copy(for: .install).detailVerb

    private func width(_ line: String) -> CGFloat {
        NSAttributedString(string: line, attributes: [.font: Self.font]).size().width
    }

    /// The subtitle lines for an estimate of `etaSeconds` at `bytesPerSecond`.
    private func downloadLines(etaSeconds: Int, bytesPerSecond: Double) -> [String] {
        let remaining = Int64((Double(etaSeconds) * bytesPerSecond).rounded())
        let progress = DownloadProgress(
            bytesWritten: 0, totalBytes: remaining, bytesPerSecond: bytesPerSecond)
        return GuestSetupProgressViewController.detailText(
            for: .download(progress), verb: Self.downloadVerb
        ).components(separatedBy: "\n")
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
        let numeric = GuestSetupProgressViewController.detailText(
            for: .download(
                DownloadProgress(bytesWritten: 0, totalBytes: 100_100, bytesPerSecond: 1_001)),
            verb: Self.downloadVerb
        ).components(separatedBy: "\n")[1]
        let placeholder = GuestSetupProgressViewController.detailText(
            for: .download(
                DownloadProgress(bytesWritten: 0, totalBytes: 99_900, bytesPerSecond: 999)),
            verb: Self.downloadVerb
        ).components(separatedBy: "\n")[1]
        #expect(abs(width(numeric) - width(placeholder)) < tolerance)
    }

    @Test("Line 1 always sets the label box: every line-2 width stays below every line-1 width")
    func line1AnchorsTheBox() {
        var line1Widths: [CGFloat] = []
        var line2Widths: [CGFloat] = []
        for speed in regimeSpeeds {
            for eta in etaBoundaries {
                let lines = downloadLines(etaSeconds: eta, bytesPerSecond: speed)
                line1Widths.append(width(lines[0]))
                line2Widths.append(width(lines[1]))
            }
        }
        // Because line 1 is always the wider line, it fixes the centered label's
        // width — so line 2 appearing, disappearing, or changing width never
        // shifts line 1.
        #expect((line2Widths.max() ?? 0) < (line1Widths.min() ?? .greatestFiniteMagnitude))
    }

    @Test("The install-phase percentage renders at a constant width across its range")
    func installPercentStable() {
        let widths = [0.0, 0.09, 0.10, 0.5, 0.99, 1.0].map {
            width(
                GuestSetupProgressViewController.detailText(
                    for: .fraction($0), verb: Self.installVerb))
        }
        let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
        #expect(spread < tolerance, "install percentage width moved by \(spread)pt")
    }

    @Test("Line 2 is omitted before the first speed sample")
    func line2AbsentWithoutSpeed() {
        let lines = GuestSetupProgressViewController.detailText(
            for: .download(
                DownloadProgress(bytesWritten: 0, totalBytes: 1_000_000, bytesPerSecond: 0)),
            verb: Self.downloadVerb
        ).components(separatedBy: "\n")
        #expect(lines.count == 1)
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

    @Test("detailLine2 is present, with the dash placeholder, when speed is below the ETA guard")
    func line2UsesPlaceholderBelowGuard() {
        let line2 = GuestSetupProgressViewController.detailLine2(
            for: .download(
                DownloadProgress(bytesWritten: 0, totalBytes: 500_000, bytesPerSecond: 500)))
        #expect(line2 != nil)
        #expect(line2?.contains(DataFormatters.etaUnknownPlaceholder) == true)
    }

    @Test("detailText composes exactly line 1, then line 2 when present")
    func detailTextComposesLines() {
        let downloading = SetupStepProgress.download(
            DownloadProgress(bytesWritten: 0, totalBytes: 100_000_000, bytesPerSecond: 10_000_000))
        let line1 = GuestSetupProgressViewController.detailLine1(
            for: downloading, verb: Self.downloadVerb)
        let line2 = GuestSetupProgressViewController.detailLine2(for: downloading)
        #expect(line2 != nil)
        #expect(
            GuestSetupProgressViewController.detailText(
                for: downloading, verb: Self.downloadVerb) == "\(line1)\n\(line2!)")

        // A fraction-only step has no line 2, so the composed text is line 1 alone.
        let installing = SetupStepProgress.fraction(0.42)
        #expect(
            GuestSetupProgressViewController.detailText(for: installing, verb: Self.installVerb)
                == GuestSetupProgressViewController.detailLine1(
                    for: installing, verb: Self.installVerb))
    }
}
