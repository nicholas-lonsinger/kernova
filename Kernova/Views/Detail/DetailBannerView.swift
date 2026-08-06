import AppKit

/// Tinted banner stacked above the settings form, naming the VM's state and
/// what the user does next.
///
/// `tint` colors both the icon and — at 10% alpha — the background.
@MainActor
final class DetailBannerView: NSView {
    init(tint: NSColor, symbolName: String, title: String, subtitle: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(tint: tint, symbolName: symbolName, title: title, subtitle: subtitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DetailBannerView does not support NSCoder")
    }

    private func build(tint: NSColor, symbolName: String, title titleText: String, subtitle subtitleText: String) {
        // Tint background + bottom hairline, drawn by NSBoxes so they adapt to
        // light/dark automatically.
        let background = NSBox()
        background.boxType = .custom
        background.titlePosition = .noTitle
        background.borderWidth = 0
        background.cornerRadius = 0
        background.fillColor = tint.withAlphaComponent(0.1)
        addFullSizeSubview(background)

        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = .separatorColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: .systemSymbol(symbolName, accessibilityDescription: ""))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .title2)
        icon.contentTintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: titleText)
        title.font = .preferredFont(forTextStyle: .headline)
        title.isSelectable = false

        let subtitle = NSTextField(wrappingLabelWithString: subtitleText)
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 0
        subtitle.isSelectable = false

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Spacing.hairline

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, textStack, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.medium
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        addSubview(separator)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
}

// MARK: - Banners

extension DetailBannerView {
    /// Banner for a VM that hasn't completed its initial boot, its subtitle
    /// naming what Start will do for the persisted setup context.
    static func initialBoot(instance: VMInstance) -> DetailBannerView {
        DetailBannerView(
            tint: StatusColor.warning,
            symbolName: "sparkles",
            title: "Initial Boot",
            subtitle: initialBootSubtitle(for: instance))
    }

    /// Banner for a VM whose last operation failed, carrying the message
    /// captured at the failure.
    static func error(message: String?) -> DetailBannerView {
        DetailBannerView(
            tint: StatusColor.error,
            symbolName: "exclamationmark.triangle.fill",
            title: "Error",
            subtitle: message ?? "The last operation failed.")
    }

    private static func initialBootSubtitle(for instance: VMInstance) -> String {
        if let linux = instance.configuration.linuxInstallContext {
            let image = linux.imageDisplayName
            if instance.hasResumableInstallDownload {
                return "An interrupted download of \(image) will resume when you click "
                    + "\(instance.startAction.label)."
            }
            return "Click \(instance.startAction.label) to download \(image) and start the "
                + "installer."
        }
        guard let context = instance.configuration.installContext else {
            return "Click Start to install macOS."
        }
        switch context.source {
        case .downloadLatest:
            if instance.hasResumableInstallDownload {
                return "An interrupted download will resume when you click Start."
            }
            return "Click Start to download the latest macOS and install."
        case .catalogVersion, .customURL:
            let version = context.version.map { "macOS \($0)" } ?? "the chosen restore image"
            if instance.hasResumableInstallDownload {
                return "An interrupted download of \(version) will resume when you click Start."
            }
            return "Click Start to download \(version) and install."
        case .localFile:
            let name = context.localIPSWURL?.lastPathComponent ?? "the selected IPSW"
            return "Click Start to install from \(name)."
        }
    }
}
