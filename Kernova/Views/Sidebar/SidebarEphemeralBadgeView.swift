import AppKit

/// Trailing accessory shown in the sidebar row while a VM is in Ephemeral Mode.
///
/// Unlike ``SidebarAgentStatusButtonView`` it reports a *policy*, not a session,
/// so it is shown whether or not the VM is running. Click opens an `NSPopover`
/// carrying the same paragraphs as the setting's info button.
@MainActor
final class SidebarEphemeralBadgeView: NSView {
    /// The accessory's fixed square dimension — also read by the sidebar
    /// snap-to-fit measurement, so it reserves the right trailing width.
    static let width: CGFloat = 16

    private let iconButton = NSButton()
    private let popoverPresenter = PopoverPresenter()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconButton.translatesAutoresizingMaskIntoConstraints = false
        iconButton.bezelStyle = .accessoryBarAction
        iconButton.isBordered = false
        iconButton.imageScaling = .scaleProportionallyDown
        iconButton.image = .systemSymbol(
            EphemeralModeCopy.badgeSymbolName,
            accessibilityDescription: EphemeralModeCopy.badgeHelpText)
        iconButton.contentTintColor = .secondaryLabelColor
        iconButton.target = self
        iconButton.action = #selector(iconTapped(_:))
        addSubview(iconButton)

        toolTip = EphemeralModeCopy.badgeHelpText

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: Self.width),
            iconButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconButton.topAnchor.constraint(equalTo: topAnchor),
            iconButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarEphemeralBadgeView does not support NSCoder")
    }

    /// Closes any open popover, so a recycled cell can't leave one anchored to
    /// a row that now shows a different VM.
    func reset() {
        popoverPresenter.close()
    }

    @objc private func iconTapped(_: NSButton) {
        if popoverPresenter.isShown {
            popoverPresenter.close()
        } else {
            popoverPresenter.show(
                content: InfoPopoverContentViewController(
                    paragraphs: EphemeralModeCopy.popoverParagraphs),
                from: self, preferredEdge: .maxX)
        }
    }
}
