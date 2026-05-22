import AppKit

/// `NSTextField` bound to an ``Observed`` `String` via an internal
/// observation loop.
///
/// **Focus-during-edit semantics.** The observation loop never overwrites the
/// field's `stringValue` while it holds first responder. AppKit's
/// `currentEditor()` returns the field editor only when the field is
/// actively editing — used as the focus predicate. Without this guard, an
/// unrelated configuration change re-fires the observation loop and
/// clobbers the user's in-progress text.
///
/// **Write semantics.** Writes back to the view model are deferred to end of
/// editing (`controlTextDidEndEditing`) — Enter or focus loss commits. Live
/// updates per keystroke would round-trip through `updateConfiguration` on
/// every character, persisting partial names to disk mid-typing.
@MainActor
final class BindableTextField: NSTextField, NSTextFieldDelegate {
    private let observed: Observed<String>
    private var observation: ObservationLoop?

    init(observed: Observed<String>, placeholder: String? = nil) {
        self.observed = observed
        super.init(frame: .zero)
        delegate = self
        translatesAutoresizingMaskIntoConstraints = false
        isEditable = true
        isSelectable = true
        isBordered = true
        bezelStyle = .squareBezel
        if let placeholder {
            placeholderString = placeholder
        }
        stringValue = observed.get()
        startObserving()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BindableTextField does not support NSCoder")
    }

    private func startObserving() {
        observation = observeRecurring(
            track: { [weak self] in _ = self?.observed.get() },
            apply: { [weak self] in
                guard let self else { return }
                // Don't clobber an in-progress edit. AppKit's field editor
                // is non-nil iff the field is currently focused.
                guard self.currentEditor() == nil else { return }
                let next = self.observed.get()
                if self.stringValue != next {
                    self.stringValue = next
                }
            }
        )
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        observed.set(stringValue)
    }
}

/// `NSButton` styled as a switch, bound to an ``Observed`` `Bool`.
///
/// Click-driven writes route through the observed setter immediately; the
/// observation loop refreshes `state` on external changes.
@MainActor
final class BindableSwitch: NSSwitch {
    private let observed: Observed<Bool>
    private var observation: ObservationLoop?

    init(observed: Observed<Bool>) {
        self.observed = observed
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        state = observed.get() ? .on : .off
        target = self
        action = #selector(toggle(_:))
        startObserving()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BindableSwitch does not support NSCoder")
    }

    private func startObserving() {
        observation = observeRecurring(
            track: { [weak self] in _ = self?.observed.get() },
            apply: { [weak self] in
                guard let self else { return }
                let next: NSControl.StateValue = self.observed.get() ? .on : .off
                if self.state != next {
                    self.state = next
                }
            }
        )
    }

    @objc private func toggle(_ sender: Any?) {
        observed.set(state == .on)
    }
}

/// `NSButton(checkboxWithTitle:)` bound to an ``Observed`` `Bool`.
@MainActor
final class BindableCheckbox: NSButton {
    private let observed: Observed<Bool>
    private var observation: ObservationLoop?

    init(title: String, observed: Observed<Bool>) {
        self.observed = observed
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.switch)
        self.title = title
        state = observed.get() ? .on : .off
        target = self
        action = #selector(toggle(_:))
        startObserving()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BindableCheckbox does not support NSCoder")
    }

    private func startObserving() {
        observation = observeRecurring(
            track: { [weak self] in _ = self?.observed.get() },
            apply: { [weak self] in
                guard let self else { return }
                let next: NSControl.StateValue = self.observed.get() ? .on : .off
                if self.state != next {
                    self.state = next
                }
            }
        )
    }

    @objc private func toggle(_ sender: Any?) {
        observed.set(state == .on)
    }
}

/// `NSPopUpButton` bound to an ``Observed`` value plus a (title, value) menu.
///
/// The button is rebuilt from `options` on every observation pass — cheap
/// enough for popups with <20 items (the typical case for adapter type /
/// boot mode / storage policy choices). For larger lists, the caller should
/// rebuild manually inside a custom observation block instead.
@MainActor
final class BindablePopUpButton<Value: Equatable>: NSPopUpButton {
    private let observed: Observed<Value>
    private var options: [(title: String, value: Value)]
    private var observation: ObservationLoop?

    init(observed: Observed<Value>, options: [(title: String, value: Value)]) {
        self.observed = observed
        self.options = options
        super.init(frame: .zero, pullsDown: false)
        translatesAutoresizingMaskIntoConstraints = false
        rebuildMenu()
        target = self
        action = #selector(selectionChanged(_:))
        startObserving()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BindablePopUpButton does not support NSCoder")
    }

    func setOptions(_ newOptions: [(title: String, value: Value)]) {
        options = newOptions
        rebuildMenu()
    }

    private func rebuildMenu() {
        removeAllItems()
        for (index, option) in options.enumerated() {
            addItem(withTitle: option.title)
            item(at: index)?.tag = index
        }
        selectMatchingItem()
    }

    private func selectMatchingItem() {
        let current = observed.get()
        if let index = options.firstIndex(where: { $0.value == current }) {
            selectItem(at: index)
        }
    }

    private func startObserving() {
        observation = observeRecurring(
            track: { [weak self] in _ = self?.observed.get() },
            apply: { [weak self] in
                self?.selectMatchingItem()
            }
        )
    }

    @objc private func selectionChanged(_ sender: Any?) {
        let idx = indexOfSelectedItem
        guard idx >= 0, idx < options.count else { return }
        observed.set(options[idx].value)
    }
}

/// `NSStepper` paired with a numeric `NSTextField` showing the current value,
/// both bound to one ``Observed`` `Int`.
@MainActor
final class BindableStepper: NSStackView {
    private let observed: Observed<Int>
    private let stepper = NSStepper()
    private let valueLabel = NSTextField(labelWithString: "")
    private var observation: ObservationLoop?

    init(
        observed: Observed<Int>,
        range: ClosedRange<Int>,
        increment: Int = 1,
        valueFormatter: ((Int) -> String)? = nil
    ) {
        self.observed = observed
        self.valueFormatter = valueFormatter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .horizontal
        spacing = 6
        alignment = .centerY

        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = Double(increment)
        stepper.valueWraps = false
        stepper.integerValue = observed.get()
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))

        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        applyLabel(for: observed.get())

        addArrangedSubview(valueLabel)
        addArrangedSubview(stepper)
        startObserving()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BindableStepper does not support NSCoder")
    }

    private let valueFormatter: ((Int) -> String)?

    private func applyLabel(for value: Int) {
        valueLabel.stringValue = valueFormatter?(value) ?? "\(value)"
    }

    private func startObserving() {
        observation = observeRecurring(
            track: { [weak self] in _ = self?.observed.get() },
            apply: { [weak self] in
                guard let self else { return }
                let value = self.observed.get()
                if self.stepper.integerValue != value {
                    self.stepper.integerValue = value
                }
                self.applyLabel(for: value)
            }
        )
    }

    @objc private func stepperChanged(_ sender: Any?) {
        let value = stepper.integerValue
        applyLabel(for: value)
        observed.set(value)
    }
}

/// `NSSlider` bound to an ``Observed`` `Double`.
@MainActor
final class BindableSlider: NSSlider {
    private let observed: Observed<Double>
    private var observation: ObservationLoop?

    init(observed: Observed<Double>, range: ClosedRange<Double>) {
        self.observed = observed
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        minValue = range.lowerBound
        maxValue = range.upperBound
        doubleValue = observed.get()
        isContinuous = false
        target = self
        action = #selector(valueChanged(_:))
        startObserving()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BindableSlider does not support NSCoder")
    }

    private func startObserving() {
        observation = observeRecurring(
            track: { [weak self] in _ = self?.observed.get() },
            apply: { [weak self] in
                guard let self else { return }
                let value = self.observed.get()
                if abs(self.doubleValue - value) > .ulpOfOne {
                    self.doubleValue = value
                }
            }
        )
    }

    @objc private func valueChanged(_ sender: Any?) {
        observed.set(doubleValue)
    }
}
