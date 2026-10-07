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
        let box = NSBox()
        box.title = "Shows VMs where"
        box.titleFont = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let lines = NSStackView(views: conditions.map { NSTextField(wrappingLabelWithString: $0) })
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = Spacing.tight
        lines.edgeInsets = NSEdgeInsets(
            top: Spacing.tight, left: Spacing.tight, bottom: Spacing.tight, right: Spacing.tight)
        box.contentView = lines
        let stack = NSStackView(views: [nameRow(field), box])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.standard
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setFrameSize(stack.fittingSize)
        return AlertConfiguration(
            title: "New Smart Group",
            message:
                "The group stays up to date as VMs change. Edit its conditions from the filter button on its header.",
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

    private static func nameField(_ name: String) -> NSTextField {
        let field = NSTextField(string: name)
        field.placeholderString = "Name"
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
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
