import AppKit

/// Banner shown above the settings pane for a macOS VM that hasn't completed
/// its initial boot yet.
///
/// AppKit reimplementation of the former SwiftUI `InitialBootBanner`. Adapts
/// its subtitle to the persisted install context so the user knows what Start
/// will do (download + install vs. install from local IPSW vs. resume an
/// interrupted download).
@MainActor
final class InitialBootBannerView: NSView {
    init(instance: VMInstance) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(subtitle: Self.subtitle(for: instance))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InitialBootBannerView does not support NSCoder")
    }

    private func build(subtitle subtitleText: String) {
        // Orange tint background + bottom hairline, drawn by NSBoxes so they
        // adapt to light/dark automatically.
        let background = NSBox()
        background.boxType = .custom
        background.titlePosition = .noTitle
        background.borderWidth = 0
        background.cornerRadius = 0
        background.fillColor = .systemOrange.withAlphaComponent(0.1)
        addFullSizeSubview(background)

        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = .separatorColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: .systemSymbol("sparkles", accessibilityDescription: ""))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .title2)
        icon.contentTintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: "Initial Boot")
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
        textStack.spacing = 2

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, textStack, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
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

    /// Install-context-aware subtitle, mirroring the SwiftUI predecessor.
    private static func subtitle(for instance: VMInstance) -> String {
        #if arch(arm64)
        guard let context = instance.configuration.installContext else {
            return "Click Start to install macOS."
        }
        switch context.source {
        case .downloadLatest:
            if instance.hasResumableInstallDownload {
                return "An interrupted download will resume when you click Start."
            }
            return "Click Start to download the latest macOS and install."
        case .localFile:
            let name = context.localIPSWURL?.lastPathComponent ?? "the selected IPSW"
            return "Click Start to install from \(name)."
        }
        #else
        return "Click Start to install macOS."
        #endif
    }
}
