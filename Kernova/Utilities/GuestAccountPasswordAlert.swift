import AppKit
import KernovaKit

/// The two secure fields the guest-account prompt gathers, plus the refusal it
/// shows when one of them is turned down.
///
/// One instance lives for the length of one prompt and is handed back to the
/// sheet unchanged when a refusal sends it up again: the typed password is this
/// view's own state, so it is still in the field while the user reads why it
/// was refused.
@MainActor
final class GuestAccountPasswordFields: NSView {
    /// Wide enough for a password and for the refusal beneath it to wrap
    /// somewhere readable; an `NSAlert` gives its accessory view whatever width
    /// the view asks for.
    private static let contentWidth: CGFloat = 300

    /// No `contentType` on either field — it is what invites the keychain's
    /// autofill panel, which has nothing to offer an account that does not
    /// exist yet.
    let passwordField = NSSecureTextField()
    let verifyField = NSSecureTextField()
    private let refusalLabel = NSTextField(wrappingLabelWithString: "")

    var password: String { passwordField.stringValue }
    var verification: String { verifyField.stringValue }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        refusalLabel.textColor = .systemRed
        refusalLabel.font = .preferredFont(forTextStyle: .caption1)
        refusalLabel.preferredMaxLayoutWidth = Self.contentWidth
        refusalLabel.isHidden = true

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Password:"), passwordField],
            [NSTextField(labelWithString: "Verify:"), verifyField],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = Spacing.standard
        grid.rowSpacing = Spacing.small
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        let stack = NSStackView(views: [grid, refusalLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.standard
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.contentWidth),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            refusalLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        resolveFrame()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GuestAccountPasswordFields does not support NSCoder")
    }

    /// Shows `message`, or takes the line away when there is nothing to refuse.
    ///
    /// Called before the sheet that displays this view is built, because an
    /// `NSAlert` lays its accessory view out from the frame the view already
    /// has — one resolved while the refusal was hidden leaves no room for it.
    func show(refusal message: String?) {
        refusalLabel.stringValue = message ?? ""
        refusalLabel.isHidden = message == nil
        resolveFrame()
    }

    private func resolveFrame() {
        layoutSubtreeIfNeeded()
        frame = NSRect(origin: .zero, size: fittingSize)
    }
}

/// The sheet that asks for the password a macOS guest's account still needs,
/// and what each of its three answers means.
///
/// Free-form rather than a core confirmation: it confirms no verb the core
/// raised — it collects the one value the bundle does not carry.
@MainActor
enum GuestAccountPasswordAlert {
    /// Names the account, not the VM: the VM is what the user clicked Start on,
    /// and the password being asked for is the guest account's rather than
    /// anything of Kernova's.
    ///
    /// Both halves of the name, the way every other surface spells this account
    /// — the full name is what the user typed into the wizard, and the short
    /// name is what they will log in as.
    static func title(fullName: String, username: String) -> String {
        "Enter the Password for \u{201C}\(fullName)\u{201D} (\(username))"
    }

    /// Why the question is back, in the words the wizard promised it in, and
    /// what skipping leaves the user with.
    ///
    /// Named for the start rather than the install, because both are states
    /// this prompt meets: an install that has still to run, and one already
    /// finished whose boot never came. Both clauses are known — the password is
    /// held in memory alone, and a boot that carries no account stops in Setup
    /// Assistant, which is where every macOS guest created before this option
    /// stopped.
    static func message(vmName: String) -> String {
        "Kernova doesn\u{2019}t save the password for the account it creates on "
            + "\u{201C}\(vmName)\u{201D}, so this start needs it again. Skip setup and "
            + "macOS asks for an account in Setup Assistant instead."
    }

    /// The alert asking for the password `prompt` names, answering through
    /// `answer`.
    ///
    /// Takes the prompt it draws rather than the request it came in on: the
    /// presenter wraps the request's own answer hook into a one-shot, and a
    /// hook reachable from here is one this could fire a second time.
    ///
    /// The trailing edge — the first button listed — creates the account, and
    /// Escape leaves the VM where it already is. "Skip Setup" sits between
    /// them because it starts the VM too: the two starting answers stay
    /// together, away from the one that starts nothing.
    ///
    /// Validated on the click rather than on the answer, with `retry` putting
    /// the sheet back up carrying the refusal: a password Virtualization turns
    /// down is worth knowing about while the field that holds it is still on
    /// screen, not after a boot has run without an account.
    static func configuration(
        prompt: GuestAccountPrompt,
        fields: GuestAccountPasswordFields,
        answer: @escaping (GuestAccountPasswordAnswer) -> Void,
        retry: @escaping (String) -> Void
    ) -> AlertConfiguration {
        AlertConfiguration(
            title: title(fullName: prompt.fullName, username: prompt.username),
            message: message(vmName: prompt.vm.name),
            buttons: [
                AlertButton("Set Up Account", role: .default) {
                    // The wizard's own rule, on the wizard's own validator, so
                    // a password this sheet accepts is one the boot can use.
                    if let refusal = MacOSGuestProvisioning.passwordRefusal(
                        fullName: prompt.fullName, username: prompt.username,
                        password: fields.password, verifiedBy: fields.verification)
                    {
                        retry(refusal)
                        return
                    }
                    answer(.password(fields.password))
                },
                AlertButton("Skip Setup") { answer(.skip) },
                AlertButton("Cancel", role: .cancel) { answer(.cancelled) },
            ],
            accessoryView: fields,
            initialFirstResponder: fields.passwordField)
    }
}
