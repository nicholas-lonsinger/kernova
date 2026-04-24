import Cocoa
import os

/// Pure AppKit view controller for the clipboard sharing window content.
///
/// Provides an editable `NSTextView` for the clipboard buffer and a status bar
/// showing the SPICE agent connection state. Observes `SpiceClipboardService`
/// properties via `withObservationTracking`.
@MainActor
final class ClipboardContentViewController: NSViewController, NSTextViewDelegate {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "ClipboardContentViewController")

    private let instance: VMInstance
    private var textView: NSTextView!
    private var statusCircle: NSView!
    private var statusLabel: NSTextField!
    private var isUpdatingFromService = false
    private var serviceObservation: ObservationLoop?

    init(instance: VMInstance) {
        self.instance = instance
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func loadView() {
        let container = NSView()

        // Text editor
        let scrollView = makeScrollableTextView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Divider
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)

        // Status bar
        let statusBar = makeStatusBar()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusBar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            divider.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            statusBar.topAnchor.constraint(equalTo: divider.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Lower content hugging so the scroll view yields space to the status bar
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateUI()
        observeServiceChanges()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingFromService else { return }
        guard let service = instance.clipboardService else {
            Self.logger.warning("Clipboard edit ignored — clipboardService is nil for VM '\(self.instance.name, privacy: .public)'")
            return
        }
        service.clipboardText = textView.string
    }

    // MARK: - Observation

    private func observeServiceChanges() {
        serviceObservation = observeRecurring(
            track: { [weak self] in
                // Read clipboardService itself so observation re-fires when it transitions nil → non-nil
                let service = self?.instance.clipboardService
                _ = service?.clipboardText
                _ = service?.isConnected
            },
            apply: { [weak self] in
                self?.updateUI()
            }
        )
    }

    private func updateUI() {
        let service = instance.clipboardService
        let isConnected = service?.isConnected ?? false

        textView.isEditable = service != nil

        // Update text view only if the service's text differs from what's displayed
        // (avoids clobbering the user's in-progress edits)
        if let serviceText = service?.clipboardText, serviceText != textView.string {
            isUpdatingFromService = true
            textView.string = serviceText
            isUpdatingFromService = false
        }

        statusCircle.layer?.backgroundColor = isConnected
            ? NSColor.systemGreen.cgColor
            : NSColor.secondaryLabelColor.cgColor
        statusLabel.stringValue = isConnected ? "Connected" : "Waiting for guest agent"
    }

    // MARK: - View Construction

    private func makeScrollableTextView() -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = self
        self.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        return scrollView
    }

    private func makeStatusBar() -> NSView {
        let circle = NSView()
        circle.wantsLayer = true
        circle.layer?.cornerRadius = 4
        circle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 8),
            circle.heightAnchor.constraint(equalToConstant: 8),
        ])
        self.statusCircle = circle

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        self.statusLabel = label

        let stack = NSStackView(views: [circle, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

        return stack
    }
}
