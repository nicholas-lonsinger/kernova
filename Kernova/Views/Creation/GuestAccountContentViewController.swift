import AppKit

/// Step 4 of the creation wizard for macOS guests: the account Virtualization
/// creates inside the guest, shown only while the wizard is creating one.
///
/// Every control writes the shared ``VMCreationViewModel`` directly, and the
/// four text fields write on every keystroke: each one feeds `canAdvance` and
/// `validationMessage`, which the shell re-reads through its observation to keep
/// the Next button and the message in step with the form.
///
/// The step itself is absent unless
/// ``VMCreationViewModel/unattendedSetupActive`` — the boot step owns the
/// toggle, which appears only for an image that can deliver an account.
@MainActor
final class GuestAccountContentViewController: NSViewController {
    private let creationVM: VMCreationViewModel

    private let fullNameField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let verifyField = NSSecureTextField()
    private let automaticLoginSwitch = NSSwitch()
    private let remoteLoginSwitch = NSSwitch()
    /// Shows the "more content below" cue while this step's content overflows the
    /// sheet; a hint only.
    private var scrollMoreIndicator: ScrollMoreIndicator?

    init(creationVM: VMCreationViewModel) {
        self.creationVM = creationVM
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GuestAccountContentViewController does not support NSCoder")
    }

    override func loadView() {
        let title = makeWizardTitle("Set Up macOS Automatically")
        let subtitle = makeWizardSubtitle(
            "macOS skips its setup questions and creates this account when the "
                + "installation finishes.")

        let form = makeForm()
        let stack = NSStackView(views: [title, subtitle, form])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.standard
        stack.setCustomSpacing(20, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = makeGroupedFormScrollView(documentView: stack)
        NSLayoutConstraint.activate([
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = scrollView
        scrollMoreIndicator = ScrollMoreIndicator(scrollView: scrollView)
    }

    // MARK: - Form construction

    private func makeForm() -> NSView {
        configureFields()
        configureSwitches()

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = Spacing.standard
        form.translatesAutoresizingMaskIntoConstraints = false

        addCard(
            [
                makeGroupedFormCardRow("Full name", control: fullNameField, fillsControl: true),
                makeGroupedFormCardRow("Account name", control: usernameField, fillsControl: true),
                makeGroupedFormCardRow("Password", control: passwordField, fillsControl: true),
                makeGroupedFormCardRow("Verify", control: verifyField, fillsControl: true),
            ], to: form)
        let caption = makeGroupedFormCaption(
            "Kernova doesn\u{2019}t save this password. If Kernova quits before the account is "
                + "created, you\u{2019}ll be asked for it again.")
        form.addArrangedSubview(caption)
        caption.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true

        addSectionHeader("Options", to: form)
        addCard(
            [
                makeGroupedFormCardRow("Log in automatically", control: automaticLoginSwitch),
                makeGroupedFormCardRow("Remote Login (SSH)", control: remoteLoginSwitch),
            ], to: form)

        return form
    }

    /// Adds a grouped card spanning the form width.
    private func addCard(_ rows: [NSView], to form: NSStackView) {
        let card = makeGroupedFormCard(rows: rows)
        form.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
    }

    /// Adds a section-header label with extra space above it and a tight gap to
    /// the card that follows.
    private func addSectionHeader(_ title: String, to form: NSStackView) {
        if let last = form.arrangedSubviews.last {
            form.setCustomSpacing(18, after: last)
        }
        let header = makeGroupedFormSectionHeader(title)
        form.addArrangedSubview(header)
        form.setCustomSpacing(6, after: header)
    }

    /// Seeds the four text fields from the model and routes their edits back.
    ///
    /// No `contentType` on the two secure fields: it is what invites the
    /// keychain's autofill panel, which has nothing to offer a guest account
    /// that does not exist yet.
    private func configureFields() {
        fullNameField.stringValue = creationVM.guestAccountFullName
        usernameField.stringValue = creationVM.guestAccountUsername
        passwordField.stringValue = creationVM.guestAccountPassword
        verifyField.stringValue = creationVM.guestAccountVerifyPassword
        for field in [fullNameField, usernameField, passwordField, verifyField] {
            field.delegate = self
        }
    }

    private func configureSwitches() {
        automaticLoginSwitch.controlSize = .small
        automaticLoginSwitch.state = creationVM.guestAccountLogsInAutomatically ? .on : .off
        automaticLoginSwitch.target = self
        automaticLoginSwitch.action = #selector(automaticLoginToggled)

        remoteLoginSwitch.controlSize = .small
        remoteLoginSwitch.state = creationVM.guestAccountEnablesRemoteLogin ? .on : .off
        remoteLoginSwitch.target = self
        remoteLoginSwitch.action = #selector(remoteLoginToggled)
    }

    // MARK: - Actions

    @objc private func automaticLoginToggled() {
        creationVM.guestAccountLogsInAutomatically = automaticLoginSwitch.state == .on
    }

    @objc private func remoteLoginToggled() {
        creationVM.guestAccountEnablesRemoteLogin = remoteLoginSwitch.state == .on
    }
}

// MARK: - NSTextFieldDelegate

extension GuestAccountContentViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        // Every field here feeds `canAdvance` and `validationMessage`, so all of
        // them write live rather than at end-of-edit.
        if field === fullNameField {
            creationVM.guestAccountFullName = fullNameField.stringValue
        } else if field === usernameField {
            creationVM.guestAccountUsername = usernameField.stringValue
        } else if field === passwordField {
            creationVM.guestAccountPassword = passwordField.stringValue
        } else if field === verifyField {
            creationVM.guestAccountVerifyPassword = verifyField.stringValue
        }
    }
}
