import AppKit

/// Reports find-bar interactions to its owner (the serial console VC), which
/// owns the match search over the terminal's scrollback + screen.
@MainActor
protocol TerminalFindBarDelegate: AnyObject {
    func findBar(_ bar: TerminalFindBar, didChangeQuery query: String)
    func findBarDidRequestNext(_ bar: TerminalFindBar)
    func findBarDidRequestPrevious(_ bar: TerminalFindBar)
    func findBarDidClose(_ bar: TerminalFindBar)
}

/// A compact ⌘F search bar: a search field, a match-count label, previous/next
/// steppers, and a close button. Stateless about matches — it just relays
/// interaction to its delegate and displays the count it's told.
@MainActor
final class TerminalFindBar: NSView, NSSearchFieldDelegate {
    weak var delegate: TerminalFindBarDelegate?

    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var query: String { searchField.stringValue }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    func updateMatchCount(current: Int, total: Int) {
        if total == 0 {
            countLabel.stringValue = searchField.stringValue.isEmpty ? "" : "No matches"
        } else {
            countLabel.stringValue = "\(current) of \(total)"
        }
    }

    private func build() {
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchFieldEntered)
        searchField.placeholderString = "Find"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .secondaryLabelColor

        let prev = makeStepper(symbol: "chevron.up", action: #selector(previousTapped))
        let next = makeStepper(symbol: "chevron.down", action: #selector(nextTapped))
        let done = NSButton(title: "Done", target: self, action: #selector(closeTapped))
        done.bezelStyle = .rounded

        let stack = NSStackView(views: [searchField, countLabel, prev, next, done])
        stack.orientation = .horizontal
        stack.spacing = Spacing.small
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    private func makeStepper(symbol: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.bezelStyle = .rounded
        button.imageScaling = .scaleProportionallyDown
        return button
    }

    @objc private func searchFieldEntered() {
        // Enter in the field advances to the next match.
        delegate?.findBar(self, didChangeQuery: searchField.stringValue)
        delegate?.findBarDidRequestNext(self)
    }

    @objc private func previousTapped() { delegate?.findBarDidRequestPrevious(self) }
    @objc private func nextTapped() { delegate?.findBarDidRequestNext(self) }
    @objc private func closeTapped() { delegate?.findBarDidClose(self) }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        delegate?.findBar(self, didChangeQuery: searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            delegate?.findBarDidClose(self)
            return true
        }
        return false
    }
}
