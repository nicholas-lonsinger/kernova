import Cocoa

/// Pure AppKit view controller for the serial console window content.
///
/// Provides a terminal-style `NSTextView` (via `SerialTextView`) that displays
/// guest serial output and forwards keyboard input, plus a status bar showing
/// connection state and character count. Observes `VMInstance` properties via
/// `withObservationTracking`.
@MainActor
final class SerialConsoleContentViewController: NSViewController {

    private let instance: VMInstance
    private var textView: SerialTextView!
    private var scrollView: NSScrollView!
    private var statusCircle: NSView!
    private var statusLabel: NSTextField!
    private var characterCountLabel: NSTextField!
    private var instanceObservation: ObservationLoop?

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

        // Terminal
        let scrollView = makeTerminalScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        self.scrollView = scrollView

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

        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateUI()
        observeInstanceChanges()
    }

    // MARK: - Observation

    private func observeInstanceChanges() {
        instanceObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.serialOutputText
                _ = self.instance.status
            },
            apply: { [weak self] in
                self?.updateUI()
            }
        )
    }

    private func updateUI() {
        let isConnected = instance.status == .running || instance.status == .paused

        // Sync serial output with scroll-position preservation
        let currentText = textView.string
        let newText = instance.serialOutputText
        if currentText != newText {
            let clipView = scrollView.contentView
            let contentHeight = textView.frame.height
            let scrollOffset = clipView.bounds.origin.y + clipView.bounds.height
            let isAtBottom = scrollOffset >= contentHeight - 10

            textView.string = newText

            if isAtBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }

        // Update status bar
        statusCircle.layer?.backgroundColor = isConnected
            ? NSColor.systemGreen.cgColor
            : NSColor.secondaryLabelColor.cgColor
        statusLabel.stringValue = isConnected ? "Connected" : "Disconnected"
        characterCountLabel.stringValue = "\(newText.count) characters"
    }

    // MARK: - View Construction

    private func makeTerminalScrollView() -> NSScrollView {
        let textView = SerialTextView()
        textView.sendInput = { [weak self] string in
            self?.instance.sendSerialInput(string)
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isFieldEditor = false
        textView.allowsUndo = false
        textView.usesFindPanel = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .init(white: 0.9, alpha: 1.0)
        textView.backgroundColor = .init(white: 0.1, alpha: 1.0)
        textView.insertionPointColor = .init(white: 0.9, alpha: 1.0)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        self.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .init(white: 0.1, alpha: 1.0)

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

        let countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        self.characterCountLabel = countLabel

        let leftStack = NSStackView(views: [circle, label])
        leftStack.orientation = .horizontal
        leftStack.spacing = 6

        let stack = NSStackView(views: [leftStack, countLabel])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)

        return stack
    }
}

// MARK: - SerialTextView

/// Custom `NSTextView` that intercepts keyboard input and forwards it
/// to the guest VM's serial input pipe instead of editing the text buffer.
final class SerialTextView: NSTextView {

    /// Closure called with raw input characters to send to the guest VM.
    var sendInput: ((String) -> Void)?

    override func keyDown(with event: NSEvent) {
        if let characters = event.characters, !characters.isEmpty {
            sendInput?(characters)
            return
        }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        sendInput?("\r")
    }

    override func deleteBackward(_ sender: Any?) {
        sendInput?("\u{7f}")
    }

    override func insertTab(_ sender: Any?) {
        sendInput?("\t")
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
    }
}
