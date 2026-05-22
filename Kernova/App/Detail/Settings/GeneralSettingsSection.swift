import AppKit

/// General section: name (with inline rename), type, boot mode, created date.
@MainActor
final class GeneralSettingsSection: NSObject, NSTextFieldDelegate {
    let section = SettingsSection(title: "General")

    private let instance: VMInstance
    private let viewModel: VMLibraryViewModel

    /// Single field for the VM name: renders as a plain right-aligned label
    /// by default, switches to an editable bezeled field while
    /// `viewModel.activeRename == .detail(instance.id)`.
    private let nameField = NSTextField(labelWithString: "")

    private var configObservation: ObservationLoop?
    private var renameObservation: ObservationLoop?
    private var didApplyInitial = false

    init(instance: VMInstance, viewModel: VMLibraryViewModel) {
        self.instance = instance
        self.viewModel = viewModel
        super.init()
        configure()
    }

    func startObserving() {
        configObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.name
                _ = self.instance.status
            },
            apply: { [weak self] in self?.applyGeneral() }
        )
        renameObservation = observeRecurring(
            track: { [weak self] in _ = self?.viewModel.activeRename },
            apply: { [weak self] in self?.applyRenameState() }
        )
        applyGeneral()
        applyRenameState()
        didApplyInitial = true
    }

    func stopObserving() {
        configObservation?.cancel()
        configObservation = nil
        renameObservation?.cancel()
        renameObservation = nil
    }

    // MARK: - Internals

    private func configure() {
        nameField.alignment = .right
        nameField.placeholderString = "Name"
        nameField.target = self
        nameField.action = #selector(nameSubmitted(_:))
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false
        applyNameFieldLabelAppearance()

        let click = NSClickGestureRecognizer(target: self, action: #selector(beginRename(_:)))
        nameField.addGestureRecognizer(click)

        let nameContainer = NSStackView()
        nameContainer.orientation = .horizontal
        nameContainer.alignment = .centerY
        nameContainer.spacing = 8
        nameContainer.setViews(
            [NSTextField(labelWithString: "Name"), settingsSpacer(), nameField], in: .leading)

        let typeRow = NSStackView()
        typeRow.setViews(
            [
                NSTextField(labelWithString: "Type"),
                settingsSpacer(),
                NSTextField(labelWithString: instance.configuration.guestOS.displayName),
            ], in: .leading)
        typeRow.orientation = .horizontal
        typeRow.spacing = 8

        let bootModeRow = NSStackView()
        bootModeRow.setViews(
            [
                NSTextField(labelWithString: "Boot Mode"),
                settingsSpacer(),
                NSTextField(labelWithString: instance.configuration.bootMode.displayName),
            ], in: .leading)
        bootModeRow.orientation = .horizontal
        bootModeRow.spacing = 8

        let createdRow = NSStackView()
        createdRow.setViews(
            [
                NSTextField(labelWithString: "Created"),
                settingsSpacer(),
                NSTextField(
                    labelWithString:
                        instance.configuration.createdAt.formatted(date: .abbreviated, time: .shortened)),
            ], in: .leading)
        createdRow.orientation = .horizontal
        createdRow.spacing = 8

        section.setBody(settingsStackRows([nameContainer, typeRow, bootModeRow, createdRow]))
    }

    private var inRenameMode: Bool {
        viewModel.activeRename == .detail(instance.id)
    }

    private func applyGeneral() {
        if !inRenameMode, nameField.stringValue != instance.name {
            nameField.stringValue = instance.name
        }
        nameField.textColor = instance.status.canRename ? .labelColor : .secondaryLabelColor
        applyRenameState()
    }

    private func applyRenameState() {
        if inRenameMode {
            applyNameFieldEditableAppearance()
            if didApplyInitial {
                if nameField.stringValue != instance.name {
                    nameField.stringValue = instance.name
                }
                section.window?.makeFirstResponder(nameField)
            }
        } else {
            applyNameFieldLabelAppearance()
        }
    }

    private func applyNameFieldLabelAppearance() {
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.isBordered = false
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
    }

    private func applyNameFieldEditableAppearance() {
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.isBordered = true
        nameField.isBezeled = true
        nameField.bezelStyle = .roundedBezel
        nameField.drawsBackground = true
        nameField.focusRingType = .default
    }

    @objc private func beginRename(_ sender: Any?) {
        guard instance.status.canRename else { return }
        viewModel.renameVM(instance)
    }

    @objc private func nameSubmitted(_ sender: Any?) {
        viewModel.commitRename(for: instance, newName: nameField.stringValue)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === nameField, inRenameMode else { return }
        if let movementInt = obj.userInfo?["NSTextMovement"] as? Int,
            let movement = NSTextMovement(rawValue: movementInt),
            movement == .cancel
        {
            viewModel.cancelRename()
            return
        }
        viewModel.commitRename(for: instance, newName: nameField.stringValue)
    }
}
