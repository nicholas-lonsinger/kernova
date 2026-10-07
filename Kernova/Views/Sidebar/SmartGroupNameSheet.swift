import AppKit

/// The sheets naming a smart group: a new one, saved from the library's
/// filter, and a rename.
@MainActor
enum SmartGroupNameSheet {
    /// Asks for the name of a new smart group showing VMs under
    /// `conditions`, starting from `suggestedName`; Create hands `create` the
    /// name typed.
    static func newSmartGroup(
        suggestedName: String, conditions: [String], create: @escaping (String) -> Void
    ) -> AlertConfiguration {
        let field = nameField(suggestedName)
        let caption = NSTextField(labelWithString: "Shows VMs where")
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        let lines = conditions.map { condition in
            let line = NSTextField(wrappingLabelWithString: condition)
            line.preferredMaxLayoutWidth = Self.contentWidth
            return line
        }
        let conditionStack = NSStackView(views: [caption] + lines)
        conditionStack.orientation = .vertical
        conditionStack.alignment = .leading
        conditionStack.spacing = Spacing.tight
        let stack = NSStackView(views: [nameRow(field), conditionStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.standard
        // `NSAlert` lays its accessory view out at the frame it is handed,
        // so the frame has to hold everything the stack's constraints place.
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(stack.fittingSize)
        return AlertConfiguration(
            title: "New Smart Group",
            message:
                "The group stays up to date as VMs change. Edit its conditions from the "
                + "\(SidebarViewMenu.smartGroupAccessibilityLabel) button on its header.",
            buttons: [
                AlertButton("Create", role: .default) { create(field.stringValue) },
                AlertButton("Cancel", role: .cancel),
            ],
            accessoryView: stack, initialFirstResponder: field)
    }

    /// Asks for a new name for the smart group named `currentName`; Rename
    /// hands `rename` the name typed.
    static func rename(currentName: String, rename: @escaping (String) -> Void) -> AlertConfiguration {
        let field = nameField(currentName)
        let row = nameRow(field)
        row.setFrameSize(row.fittingSize)
        return AlertConfiguration(
            title: "Rename Smart Group",
            message: "",
            buttons: [
                AlertButton("Rename", role: .default) { rename(field.stringValue) },
                AlertButton("Cancel", role: .cancel),
            ],
            accessoryView: row, initialFirstResponder: field)
    }

    /// How wide the name field is, and how wide a condition wraps at.
    private static let contentWidth: CGFloat = 240

    private static func nameField(_ name: String) -> NSTextField {
        let field = NSTextField(string: name)
        field.placeholderString = "Name"
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return field
    }

    private static func nameRow(_ field: NSTextField) -> NSStackView {
        let row = NSStackView(views: [NSTextField(labelWithString: "Name:"), field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Spacing.standard
        return row
    }
}
