import AppKit
import UniformTypeIdentifiers

/// Step 2 (macOS): Choose an IPSW restore image source.
@MainActor
final class IPSWSelectionStepViewController: CreationStepViewController {
    private let downloadButton = NSButton()
    private let localButton = NSButton()
    private let pathLabel = NSTextField(labelWithString: "")
    private let changeButton = NSButton()
    private let pathBadge = NSStackView()
    private let overwriteBanner = NSStackView()
    private let resumeBanner = NSStackView()
    private var observation: ObservationLoop?

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = makeStepHeader(
            title: "macOS Restore Image",
            subtitle: "Choose how to obtain the macOS restore image (IPSW) for installation."
        )

        configureSourceButton(
            downloadButton,
            title: "Download Latest",
            subtitle: "Download the latest compatible macOS restore image from Apple.",
            tag: 0
        )
        configureSourceButton(
            localButton,
            title: "Choose Local File…",
            subtitle: "Select an IPSW file already on your Mac.",
            tag: 1
        )

        pathLabel.font = .preferredFont(forTextStyle: .caption1)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        changeButton.title = "Change…"
        changeButton.target = self
        changeButton.action = #selector(changePath(_:))
        changeButton.bezelStyle = .accessoryBarAction
        changeButton.controlSize = .small

        let badgeIcon = NSImageView(
            image: .systemSymbol("doc.fill", accessibilityDescription: "")
        )
        badgeIcon.contentTintColor = .secondaryLabelColor
        pathBadge.setViews([badgeIcon, pathLabel, changeButton], in: .leading)
        pathBadge.orientation = .horizontal
        pathBadge.spacing = 6
        pathBadge.translatesAutoresizingMaskIntoConstraints = false

        configureOverwriteBanner()
        configureResumeBanner()

        let stack = NSStackView(views: [
            header, downloadButton, localButton, pathBadge, overwriteBanner, resumeBanner,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            downloadButton.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            downloadButton.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            localButton.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            localButton.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])

        view = container

        observation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.creationVM.ipswSource
                _ = self.creationVM.ipswPath
                _ = self.creationVM.ipswDownloadPath
                _ = self.creationVM.shouldShowOverwriteWarning
                _ = self.creationVM.hasResumableDownload
            },
            apply: { [weak self] in self?.refresh() }
        )
        refresh()
    }

    // MARK: - Banner construction

    private func configureOverwriteBanner() {
        let icon = NSImageView(
            image: .systemSymbol("exclamationmark.triangle.fill", accessibilityDescription: "")
        )
        icon.contentTintColor = NSColor.systemYellow

        let label = NSTextField(
            wrappingLabelWithString:
                "A file already exists at this location. It will be replaced when downloading."
        )
        label.font = .preferredFont(forTextStyle: .callout)
        label.maximumNumberOfLines = 0
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let useExisting = NSButton(
            title: "Use Existing File",
            target: self,
            action: #selector(useExistingFile(_:))
        )
        useExisting.controlSize = .small

        let confirm = NSButton(
            title: "Download & Replace",
            target: self,
            action: #selector(confirmOverwrite(_:))
        )
        confirm.controlSize = .small

        overwriteBanner.setViews([icon, label, useExisting, confirm], in: .leading)
        overwriteBanner.orientation = .horizontal
        overwriteBanner.spacing = 8
        overwriteBanner.alignment = .centerY
    }

    private func configureResumeBanner() {
        let icon = NSImageView(
            image: .systemSymbol("arrow.clockwise.circle.fill", accessibilityDescription: "")
        )
        icon.contentTintColor = NSColor.systemBlue

        let label = NSTextField(
            wrappingLabelWithString:
                "A previous download was interrupted at this location. It will resume when the install starts."
        )
        label.font = .preferredFont(forTextStyle: .callout)
        label.maximumNumberOfLines = 0

        resumeBanner.setViews([icon, label], in: .leading)
        resumeBanner.orientation = .horizontal
        resumeBanner.spacing = 8
        resumeBanner.alignment = .centerY
    }

    // MARK: - Source button configuration

    private func configureSourceButton(_ button: NSButton, title: String, subtitle: String, tag: Int) {
        button.title = "\(title)\n\(subtitle)"
        button.target = self
        button.action = #selector(sourcePicked(_:))
        button.bezelStyle = .regularSquare
        button.alignment = .left
        button.imagePosition = .imageLeading
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tag = tag
        button.heightAnchor.constraint(equalToConstant: 56).isActive = true
    }

    // MARK: - Refresh

    private func refresh() {
        downloadButton.state = (creationVM.ipswSource == .downloadLatest) ? .on : .off
        localButton.state = (creationVM.ipswSource == .localFile) ? .on : .off

        switch creationVM.ipswSource {
        case .downloadLatest:
            if let path = creationVM.ipswDownloadPath {
                pathBadge.isHidden = false
                pathLabel.stringValue = Self.abbreviateWithTilde(path)
            } else {
                pathBadge.isHidden = true
            }
        case .localFile:
            if let path = creationVM.ipswPath {
                pathBadge.isHidden = false
                pathLabel.stringValue = Self.abbreviateWithTilde(path)
            } else {
                pathBadge.isHidden = true
            }
        }

        overwriteBanner.isHidden = !(creationVM.ipswSource == .downloadLatest && creationVM.shouldShowOverwriteWarning)
        resumeBanner.isHidden =
            !(creationVM.ipswSource == .downloadLatest
            && !creationVM.shouldShowOverwriteWarning
            && creationVM.hasResumableDownload)
    }

    // MARK: - Actions

    @objc private func sourcePicked(_ sender: NSButton) {
        if sender === downloadButton {
            creationVM.ipswSource = .downloadLatest
            if creationVM.ipswDownloadPath == nil {
                creationVM.ipswDownloadPath = VMCreationViewModel.defaultIPSWDownloadPath
            }
        } else if sender === localButton {
            selectIPSWFile()
        }
    }

    @objc private func changePath(_ sender: Any?) {
        switch creationVM.ipswSource {
        case .downloadLatest: selectDownloadDestination()
        case .localFile: selectIPSWFile()
        }
    }

    @objc private func useExistingFile(_ sender: Any?) {
        creationVM.useExistingDownloadFile()
    }

    @objc private func confirmOverwrite(_ sender: Any?) {
        creationVM.confirmOverwrite()
    }

    // MARK: - File panels

    private func selectIPSWFile() {
        let panel = NSOpenPanel()
        panel.title = "Select macOS Restore Image"
        panel.allowedContentTypes = [.ipsw]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let window = view.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if response == .OK, let url = panel.url {
                        self.creationVM.ipswSource = .localFile
                        self.creationVM.ipswPath = url.path(percentEncoded: false)
                    }
                }
            }
        }
    }

    private func selectDownloadDestination() {
        let panel = NSSavePanel()
        panel.title = "Choose Download Location"
        if let currentPath = creationVM.ipswDownloadPath {
            let currentURL = URL(fileURLWithPath: currentPath)
            panel.directoryURL = currentURL.deletingLastPathComponent()
            panel.nameFieldStringValue = currentURL.lastPathComponent
        } else {
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.nameFieldStringValue = "RestoreImage.ipsw"
        }
        panel.allowedContentTypes = [.ipsw]
        if let window = view.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if response == .OK, let url = panel.url {
                        self.creationVM.ipswDownloadPath = url.path(percentEncoded: false)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    static func abbreviateWithTilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
