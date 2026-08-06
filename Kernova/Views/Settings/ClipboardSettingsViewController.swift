import AppKit
import KernovaKit
import os

/// The "Clipboard" pane of the Settings window.
///
/// Hosts the maximum paste size — the ceiling on the total of one paste's file
/// representations, backed by `AppPreferences`. App-wide rather than per-VM: the
/// value the ceiling trades against is this Mac's throughput against a fixed OS
/// paste deadline, while a `VMConfiguration` field would travel inside the VM
/// bundle to machines with different throughput.
///
/// A change reaches a running guest agent through
/// `VMLibraryViewModel.applyClipboardPasteLimitChange()`; the host's own checks
/// read the preference at each paste and need no push.
@MainActor
final class ClipboardSettingsViewController: NSViewController {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "ClipboardSettingsViewController")

    /// The static half of the explanation — what the limit governs.
    static let deadlineCaption =
        "Copied files transfer while the pasting app waits, and macOS gives that wait a deadline — "
        + "about 60 seconds in Finder, about 120 seconds in other apps. Kernova refuses a larger "
        + "paste up front rather than running out the clock and delivering nothing."

    private let preferences: AppPreferences
    private let viewModel: VMLibraryViewModel

    private let sizePopUp = NSPopUpButton()
    private let estimateCaption = makeGroupedFormCaption("")

    init(preferences: AppPreferences = .shared, viewModel: VMLibraryViewModel) {
        self.preferences = preferences
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "Clipboard"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClipboardSettingsViewController does not support NSCoder")
    }

    /// What one ceiling costs in transfer time, so the trade the selection makes
    /// is legible at the moment it is made rather than at the failed paste.
    static func estimateText(for bytes: Int) -> String {
        let throughput = ClipboardPasteLimit.displayLimit(
            ClipboardPasteLimit.measuredThroughputBytesPerSecond)
        let seconds = ClipboardPasteLimit.estimatedStreamSeconds(bytes)
        return
            "At Kernova's measured \(throughput)/s, \(ClipboardPasteLimit.displayLimit(bytes)) "
            + "transfers in about \(seconds) second\(seconds == 1 ? "" : "s") — before a copied "
            + "folder's archive and extract passes."
    }

    /// The menu title for one ceiling, marking the value the deadline derives.
    static func itemTitle(for bytes: Int) -> String {
        let title = ClipboardPasteLimit.displayLimit(bytes)
        return bytes == ClipboardPasteLimit.defaultBytes ? "\(title) (Recommended)" : title
    }

    override func loadView() {
        sizePopUp.controlSize = .small
        for bytes in ClipboardPasteLimit.choices {
            sizePopUp.addItem(withTitle: Self.itemTitle(for: bytes))
            sizePopUp.lastItem?.representedObject = bytes
        }
        sizePopUp.target = self
        sizePopUp.action = #selector(maxPasteSizeChanged)

        let card = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("Maximum paste size", control: sizePopUp)
        ])

        let section = NSStackView(views: [
            makeGroupedFormSectionHeader("Clipboard Transfers"),
            card,
            makeGroupedFormCaption(Self.deadlineCaption),
            estimateCaption,
        ])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = Spacing.small
        section.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        // Let the root's size flow from its content — see the same note in
        // `AdvancedSettingsViewController`.
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(section)
        let pad = Spacing.large
        NSLayoutConstraint.activate([
            section.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            section.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            section.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            section.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            root.widthAnchor.constraint(equalToConstant: SettingsPaneMetrics.width),
            card.widthAnchor.constraint(equalTo: section.widthAnchor),
            estimateCaption.widthAnchor.constraint(equalTo: section.widthAnchor),
        ])
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        // Drive NSTabViewController's per-tab window resize from the measured
        // fitting height, after `refresh()` has settled the estimate line's own.
        preferredContentSize = view.fittingSize
    }

    /// Selects the stored ceiling and renders its estimate.
    private func refresh() {
        let stored = preferences.clipboardMaxPasteBytes
        // `AppPreferences` resolves onto the ladder on read, so a miss here means
        // the two lists have diverged, not that the user stored something odd.
        guard let index = ClipboardPasteLimit.choices.firstIndex(of: stored) else {
            Self.logger.fault(
                "Stored paste ceiling \(stored, privacy: .public) is not an offered choice")
            assertionFailure("Stored paste ceiling \(stored) is not an offered choice")
            estimateCaption.stringValue = Self.estimateText(for: stored)
            return
        }
        sizePopUp.selectItem(at: index)
        estimateCaption.stringValue = Self.estimateText(for: stored)
    }

    @objc private func maxPasteSizeChanged() {
        guard let bytes = sizePopUp.selectedItem?.representedObject as? Int else { return }
        preferences.clipboardMaxPasteBytes = bytes
        estimateCaption.stringValue = Self.estimateText(for: bytes)
        // The guest enforces its own copy of the ceiling, so a running agent
        // has to be told; the host's checks read the preference directly.
        viewModel.applyClipboardPasteLimitChange()
    }
}
