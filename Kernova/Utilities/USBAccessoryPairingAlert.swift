import AppKit

/// The alert that asks which running guest a newly assigned USB accessory
/// should be passed through to.
///
/// Free-form rather than a core confirmation: it confirms no verb the core
/// raised — it asks a question the user has not been asked yet, and the answer
/// is what runs the attach.
@MainActor
enum USBAccessoryPairingAlert {
    /// The question, naming the one guest that could take the accessory — or
    /// naming none, when the user has to pick.
    static func title(accessory: String, vmName: String?) -> String {
        guard let vmName else {
            return "Pass \u{201C}\(accessory)\u{201D} through to a virtual machine?"
        }
        return "Pass \u{201C}\(accessory)\u{201D} through to \u{201C}\(vmName)\u{201D}?"
    }

    /// What passing it through costs, and what it buys.
    ///
    /// Both clauses are known: a guest's capture is exclusive and terminates
    /// the host's other clients, and the remembering is what the button does.
    static func message(vmName: String?) -> String {
        guard let vmName else {
            return
                "While a virtual machine holds this accessory, macOS cannot use it. Kernova will pass it through to the one you choose again whenever both are available."
        }
        return
            "While \u{201C}\(vmName)\u{201D} holds this accessory, macOS cannot use it. Kernova will pass it through to \u{201C}\(vmName)\u{201D} again whenever both are available."
    }

    /// The alert `request` asks with.
    ///
    /// "Pass Through" is the CLI's own wording; "Keep on Mac" names the outcome
    /// rather than saying Cancel. The trailing edge — the first button listed —
    /// is the action, and Escape keeps the accessory where it already is.
    ///
    /// No "don't ask again": answering creates the pairing, so the question
    /// never returns for that device, and an app-wide suppression would leave a
    /// user with a newly plugged accessory, no prompt, and no cue that the USB
    /// Device menu is where to go.
    static func configuration(for request: USBAccessoryPairingRequest) -> AlertConfiguration {
        let single = request.candidates.count == 1 ? request.candidates[0] : nil
        let chooser = single == nil ? makeChooser(for: request.candidates) : nil
        let candidates = request.candidates
        let answer = request.answer
        return AlertConfiguration(
            title: title(accessory: request.accessory.name, vmName: single?.name),
            message: message(vmName: single?.name),
            buttons: [
                AlertButton("Pass Through", role: .default) {
                    guard let chooser else {
                        answer(single)
                        return
                    }
                    // Read at click time, and off the selected item's tag
                    // rather than its row: the tag is the index the item was
                    // built from, and it survives anything AppKit does to the
                    // menu's order.
                    guard let index = chooser.selectedItem?.tag,
                        candidates.indices.contains(index)
                    else {
                        answer(nil)
                        return
                    }
                    answer(candidates[index])
                },
                AlertButton("Keep on Mac", role: .cancel) { answer(nil) },
            ],
            accessoryView: chooser.map(makeChooserRow))
    }

    /// The popup listing every guest that could take the accessory, one row
    /// per candidate and each row tagged with the candidate it stands for.
    ///
    /// Built item by item rather than through `addItem(withTitle:)`, which
    /// treats a title as an identity: adding one an existing item already
    /// carries moves that item to the end instead of adding a row. Nothing
    /// makes VM names unique, so two guests called the same thing would
    /// otherwise produce one row fewer than there are candidates and shift
    /// every row's meaning — handing the accessory to a guest the user did not
    /// pick, and writing the pairing against it.
    private static func makeChooser(for candidates: [VMInstance]) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.translatesAutoresizingMaskIntoConstraints = false
        let menu = NSMenu()
        for (index, candidate) in candidates.enumerated() {
            let item = NSMenuItem()
            item.title = candidate.name
            item.tag = index
            menu.addItem(item)
        }
        popUp.menu = menu
        popUp.selectItem(at: 0)
        return popUp
    }

    private static func makeChooserRow(_ chooser: NSPopUpButton) -> NSView {
        let label = NSTextField(labelWithString: "Virtual machine:")
        label.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, chooser])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Spacing.standard
        row.translatesAutoresizingMaskIntoConstraints = false
        // An `NSAlert` accessory view is laid out from its frame, so the stack
        // has to have resolved one before the sheet is built.
        row.layoutSubtreeIfNeeded()
        row.frame = NSRect(origin: .zero, size: row.fittingSize)
        return row
    }
}
