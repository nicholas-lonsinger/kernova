import Cocoa

/// Pure AppKit view controller for the serial console window content.
///
/// Hosts a `TerminalView` that renders the VM's `TerminalEmulator` grid and
/// forwards keyboard input to the guest, a status bar (connection state + grid
/// size), and a toggleable ⌘F find bar. Observes `VMInstance.status` via
/// `observeRecurring` for the connection indicator; the terminal's own redraw
/// is driven directly by the emulator's `onRender` hook, off the observation path.
@MainActor
final class SerialConsoleContentViewController: NSViewController, TerminalFindBarDelegate {
    private let instance: VMInstance
    private let terminalView: TerminalView
    private let findBar = TerminalFindBar()
    private var findBarHeight: NSLayoutConstraint!
    private let statusCircle: NSView
    private let statusLabel: NSTextField
    private let gridSizeLabel: NSTextField
    private var statusObservation: ObservationLoop?
    private var keyMonitor: Any?

    private struct Match {
        let line: Int
        let colStart: Int
        let colEnd: Int
    }
    private var matches: [Match] = []
    private var currentMatchIndex = 0

    init(instance: VMInstance) {
        self.instance = instance
        self.terminalView = TerminalView(emulator: instance.terminal)

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

        let gridLabel = NSTextField(labelWithString: "")
        gridLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        gridLabel.textColor = .secondaryLabelColor
        gridLabel.alignment = .right
        self.gridSizeLabel = gridLabel

        super.init(nibName: nil, bundle: nil)

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.sendInput = { [weak self] string in
            self?.instance.sendSerialInput(string)
        }
        terminalView.onGridSizeChange = { [weak self] cols, rows in
            self?.gridSizeLabel.stringValue = "\(cols) × \(rows)"
        }

        findBar.delegate = self
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = TerminalTheme.defaultBackground.cgColor

        container.addSubview(findBar)
        container.addSubview(terminalView)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)

        let statusBar = makeStatusBar()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusBar)

        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: container.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findBarHeight,

            terminalView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            divider.topAnchor.constraint(equalTo: terminalView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            statusBar.topAnchor.constraint(equalTo: divider.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateStatusBar()
        observeStatus()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(terminalView)
        installKeyMonitor()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeKeyMonitor()
    }

    // MARK: - Observation

    private func observeStatus() {
        statusObservation = observeRecurring(
            track: { [weak self] in
                _ = self?.instance.status
            },
            apply: { [weak self] in
                self?.updateStatusBar()
            }
        )
    }

    private func updateStatusBar() {
        let isConnected = instance.status == .running || instance.status == .paused
        statusCircle.layer?.backgroundColor =
            isConnected ? NSColor.systemGreen.cgColor : NSColor.secondaryLabelColor.cgColor
        statusLabel.stringValue = isConnected ? "Connected" : "Disconnected"
        gridSizeLabel.stringValue = "\(instance.terminal.cols) × \(instance.terminal.rows)"
    }

    // MARK: - View Construction

    private func makeStatusBar() -> NSView {
        let leftStack = NSStackView(views: [statusCircle, statusLabel])
        leftStack.orientation = .horizontal
        leftStack.spacing = Spacing.small

        let stack = NSStackView(views: [leftStack, gridSizeLabel])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        return stack
    }

    // MARK: - Find

    private var isFindBarVisible: Bool { !findBar.isHidden }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.view.window?.isKeyWindow == true else { return event }
            if event.modifierFlags.contains(.command),
                event.charactersIgnoringModifiers?.lowercased() == "f"
            {
                self.toggleFindBar()
                return nil
            }
            if event.keyCode == 53, self.isFindBarVisible {  // Escape
                self.hideFindBar()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func toggleFindBar() {
        if isFindBarVisible { hideFindBar() } else { showFindBar() }
    }

    private func showFindBar() {
        findBar.isHidden = false
        findBarHeight.constant = 30
        findBar.focusSearchField()
        recomputeMatches()
    }

    private func hideFindBar() {
        findBar.isHidden = true
        findBarHeight.constant = 0
        matches.removeAll()
        terminalView.clearFindHighlight()
        view.window?.makeFirstResponder(terminalView)
    }

    private func recomputeMatches() {
        matches.removeAll()
        let query = findBar.query
        guard !query.isEmpty else {
            terminalView.clearFindHighlight()
            findBar.updateMatchCount(current: 0, total: 0)
            return
        }
        let lines = terminalView.searchableLines()
        for (index, line) in lines.enumerated() {
            var start = line.startIndex
            while let range = line.range(of: query, options: .caseInsensitive, range: start..<line.endIndex) {
                let colStart = line.distance(from: line.startIndex, to: range.lowerBound)
                let colEnd = colStart + line.distance(from: range.lowerBound, to: range.upperBound)
                matches.append(Match(line: index, colStart: colStart, colEnd: colEnd))
                start = range.upperBound
                if start == line.endIndex { break }
            }
        }
        currentMatchIndex = 0
        if matches.isEmpty {
            terminalView.clearFindHighlight()
            findBar.updateMatchCount(current: 0, total: 0)
        } else {
            highlightCurrentMatch()
        }
    }

    private func highlightCurrentMatch() {
        guard !matches.isEmpty else { return }
        let match = matches[currentMatchIndex]
        terminalView.highlightMatch(absoluteLine: match.line, colStart: match.colStart, colEnd: match.colEnd)
        findBar.updateMatchCount(current: currentMatchIndex + 1, total: matches.count)
    }

    // MARK: - TerminalFindBarDelegate

    func findBar(_ bar: TerminalFindBar, didChangeQuery query: String) {
        recomputeMatches()
    }

    func findBarDidRequestNext(_ bar: TerminalFindBar) {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
        highlightCurrentMatch()
    }

    func findBarDidRequestPrevious(_ bar: TerminalFindBar) {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
        highlightCurrentMatch()
    }

    func findBarDidClose(_ bar: TerminalFindBar) {
        hideFindBar()
    }
}
