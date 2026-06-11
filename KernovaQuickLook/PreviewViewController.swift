import AppKit
import QuickLookUI
import os

/// Renders the `.kernova` info card inside the system Quick Look panel.
///
/// View-based (`QLIsDataBasedPreview = false`) so the card is ordinary AppKit:
/// semantic colors track light/dark appearance automatically, matching the
/// app's AppKit-first idiom. Everything here reads the bundle; nothing writes —
/// the sandbox grants the previewed item read-only access anyway.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private static let logger = Logger(subsystem: "app.kernova", category: "QuickLookPreview")

    private enum Metrics {
        static let contentInset: CGFloat = 28
        static let tileSize: CGFloat = 56
        static let usageBarWidth: CGFloat = 240
        static let usageBarHeight: CGFloat = 5
        static let minPanelWidth: CGFloat = 500
    }

    // Nib-less: the extension ships no storyboard, so `loadView` must not fall
    // through to NSViewController's nib lookup.
    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL) async throws {
        Self.logger.debug("Preparing preview for \(url.lastPathComponent, privacy: .public)")
        let model: VMPreviewModel
        do {
            let configuration = try VMConfiguration.load(fromBundle: url)
            model = VMPreviewModel(configuration: configuration, layout: VMBundleLayout(bundleURL: url))
        } catch {
            Self.logger.error(
                "Could not read configuration in \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            model = .unreadable(bundleURL: url)
        }
        render(model)
    }

    // MARK: - Card assembly

    private func render(_ model: VMPreviewModel) {
        view.subviews.forEach { $0.removeFromSuperview() }

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false

        content.addArrangedSubview(makeHeader(model))
        if !model.fields.isEmpty {
            let separator = NSBox()
            separator.boxType = .separator
            content.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            content.addArrangedSubview(makeGrid(model.fields))
        }

        let footer = NSTextField(labelWithString: model.footer)
        footer.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        footer.textColor = .tertiaryLabelColor
        content.addArrangedSubview(footer)

        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.contentInset),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.contentInset),
            content.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -Metrics.contentInset),
            content.bottomAnchor.constraint(
                lessThanOrEqualTo: view.bottomAnchor, constant: -Metrics.contentInset),
        ])

        let fitting = content.fittingSize
        preferredContentSize = NSSize(
            width: max(Metrics.minPanelWidth, fitting.width + Metrics.contentInset * 2),
            height: fitting.height + Metrics.contentInset * 2)
    }

    private func makeHeader(_ model: VMPreviewModel) -> NSView {
        let nameLabel = NSTextField(labelWithString: model.name)
        nameLabel.font = .systemFont(ofSize: 21, weight: .bold)
        nameLabel.lineBreakMode = .byTruncatingTail

        let subtitleLabel = NSTextField(labelWithString: model.subtitle)
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor

        var subtitleViews: [NSView] = [subtitleLabel]
        if let badge = model.badge {
            subtitleViews.append(makeBadge(badge))
        }
        let subtitleRow = NSStackView(views: subtitleViews)
        subtitleRow.orientation = .horizontal
        subtitleRow.spacing = 8

        let titleColumn = NSStackView(views: [nameLabel, subtitleRow])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 3

        let header = NSStackView(views: [makeIconTile(model), titleColumn])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14
        return header
    }

    /// The rounded glyph tile leading the header — `VMGuestOS.iconName` at
    /// display size on a subtle appearance-aware fill.
    private func makeIconTile(_ model: VMPreviewModel) -> NSView {
        let tile = NSBox()
        tile.boxType = .custom
        tile.borderWidth = 0
        tile.cornerRadius = 12
        tile.fillColor = .quaternaryLabelColor
        tile.contentViewMargins = .zero
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: Metrics.tileSize),
            tile.heightAnchor.constraint(equalToConstant: Metrics.tileSize),
        ])

        guard let symbol = NSImage(systemSymbolName: model.iconName, accessibilityDescription: model.subtitle)
        else {
            Self.logger.fault("SF Symbol lookup failed for '\(model.iconName, privacy: .public)'")
            assertionFailure("SF Symbol lookup failed for: \(model.iconName)")
            return tile
        }
        let imageView = NSImageView(
            image: symbol.withSymbolConfiguration(.init(pointSize: 26, weight: .medium)) ?? symbol)
        imageView.contentTintColor = .labelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        if let tileContent = tile.contentView {
            tileContent.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: tileContent.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: tileContent.centerYAnchor),
            ])
        }
        return tile
    }

    private func makeBadge(_ badge: VMPreviewModel.Badge) -> NSView {
        let color: NSColor =
            switch badge {
            case .suspended: .systemOrange
            case .installPending: .controlAccentColor
            }

        let label = NSTextField(labelWithString: badge.displayName)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSBox()
        pill.boxType = .custom
        pill.borderWidth = 0
        pill.cornerRadius = 9
        pill.fillColor = color.withAlphaComponent(0.16)
        pill.contentViewMargins = .zero
        pill.translatesAutoresizingMaskIntoConstraints = false
        if let pillContent = pill.contentView {
            pillContent.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: pillContent.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: pillContent.trailingAnchor, constant: -8),
                label.topAnchor.constraint(equalTo: pillContent.topAnchor, constant: 2),
                label.bottomAnchor.constraint(equalTo: pillContent.bottomAnchor, constant: -2),
            ])
        }
        return pill
    }

    private func makeGrid(_ fields: [VMPreviewModel.Field]) -> NSGridView {
        let rows: [[NSView]] = fields.map { field in
            let label = NSTextField(labelWithString: field.label)
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor

            let value = NSTextField(labelWithString: field.value)
            value.font = .systemFont(ofSize: 13)
            value.lineBreakMode = .byTruncatingMiddle

            guard let usedFraction = field.usedFraction else { return [label, value] }
            let valueColumn = NSStackView(views: [value, makeUsageBar(usedFraction)])
            valueColumn.orientation = .vertical
            valueColumn.alignment = .leading
            valueColumn.spacing = 5
            return [label, valueColumn]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        return grid
    }

    /// A thin track/fill bar visualizing the main disk's on-disk footprint
    /// against its allocated capacity.
    private func makeUsageBar(_ fraction: Double) -> NSView {
        let track = NSBox()
        track.boxType = .custom
        track.borderWidth = 0
        track.cornerRadius = Metrics.usageBarHeight / 2
        track.fillColor = .quaternaryLabelColor
        track.contentViewMargins = .zero
        track.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            track.widthAnchor.constraint(equalToConstant: Metrics.usageBarWidth),
            track.heightAnchor.constraint(equalToConstant: Metrics.usageBarHeight),
        ])

        let fill = NSBox()
        fill.boxType = .custom
        fill.borderWidth = 0
        fill.cornerRadius = Metrics.usageBarHeight / 2
        fill.fillColor = .controlAccentColor
        fill.contentViewMargins = .zero
        fill.translatesAutoresizingMaskIntoConstraints = false
        if let trackContent = track.contentView {
            trackContent.addSubview(fill)
            NSLayoutConstraint.activate([
                fill.leadingAnchor.constraint(equalTo: trackContent.leadingAnchor),
                fill.topAnchor.constraint(equalTo: trackContent.topAnchor),
                fill.bottomAnchor.constraint(equalTo: trackContent.bottomAnchor),
                fill.widthAnchor.constraint(
                    equalTo: trackContent.widthAnchor, multiplier: max(0, min(1, fraction))),
            ])
        }
        return track
    }
}
