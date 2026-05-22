import AppKit
import os

/// Settings form for editing a stopped VM's configuration, or viewing a
/// running VM's configuration in read-only mode.
///
/// This controller is a thin coordinator: each ``SettingsSection`` lives in
/// its own `*SettingsSection.swift` file (General, Resources, Storage,
/// Removable, Shared, Network, Audio, Guest Agent, Clipboard). The
/// coordinator stacks the sections inside a scrolling document view, owns
/// the read-only / initial-boot banners, and drives a shared
/// ``AttachmentFileMonitor`` so missing-file badges on attachment rows
/// stay accurate.
@MainActor
final class VMSettingsViewController: NSViewController {
    private static let logger = Logger(
        subsystem: "com.kernova.app", category: "VMSettingsViewController")

    private let instance: VMInstance
    private let viewModel: VMLibraryViewModel
    private let isReadOnly: Bool
    private let showInitialBootBanner: Bool

    // MARK: - Section controllers

    private let generalSection: GeneralSettingsSection
    private let resourcesSection: ResourcesSettingsSection
    private let storageSection: StorageSettingsSection
    private let removableSection: RemovableMediaSettingsSection
    private let sharedSection: SharedDirectoriesSettingsSection
    private let networkSection: NetworkSettingsSection
    private let audioSection: AudioSettingsSection
    private let guestAgentSection: GuestAgentSettingsSection?
    private let clipboardSection: ClipboardSettingsSection

    private let readOnlyBanner = NSStackView()
    private let initialBootBanner = NSStackView()

    // MARK: - State

    private let fileMonitor = AttachmentFileMonitor()
    private var fileMonitorObservation: ObservationLoop?

    // MARK: - Init

    init(
        instance: VMInstance,
        viewModel: VMLibraryViewModel,
        isReadOnly: Bool,
        showInitialBootBanner: Bool = false
    ) {
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
        self.showInitialBootBanner = showInitialBootBanner

        self.generalSection = GeneralSettingsSection(
            instance: instance, viewModel: viewModel)
        self.resourcesSection = ResourcesSettingsSection(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
        self.storageSection = StorageSettingsSection(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly,
            fileMonitor: fileMonitor)
        self.removableSection = RemovableMediaSettingsSection(
            instance: instance, viewModel: viewModel, fileMonitor: fileMonitor)
        self.sharedSection = SharedDirectoriesSettingsSection(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
        self.networkSection = NetworkSettingsSection(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
        self.audioSection = AudioSettingsSection(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
        self.guestAgentSection =
            instance.configuration.guestOS == .macOS
            ? GuestAgentSettingsSection(instance: instance, viewModel: viewModel)
            : nil
        self.clipboardSection = ClipboardSettingsSection(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMSettingsViewController does not support NSCoder")
    }

    // MARK: - Lifecycle

    override func loadView() {
        configureReadOnlyBanner()
        configureInitialBootBanner()

        let sectionStack = NSStackView()
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 16
        sectionStack.translatesAutoresizingMaskIntoConstraints = false

        if isReadOnly { sectionStack.addArrangedSubview(readOnlyBanner) }
        if showInitialBootBanner { sectionStack.addArrangedSubview(initialBootBanner) }

        let sectionViews: [SettingsSection] = [
            generalSection.section,
            resourcesSection.section,
            storageSection.section,
            removableSection.section,
            sharedSection.section,
            networkSection.section,
            audioSection.section,
        ]
        for section in sectionViews {
            sectionStack.addArrangedSubview(section)
        }
        if let guestAgentSection {
            sectionStack.addArrangedSubview(guestAgentSection.section)
        }
        sectionStack.addArrangedSubview(clipboardSection.section)

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(sectionStack)
        NSLayoutConstraint.activate([
            sectionStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 16),
            sectionStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
            sectionStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            sectionStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -16),
        ])

        let scroll = NSScrollView()
        scroll.documentView = documentView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addFullSizeSubview(scroll)
        view = container

        // RATIONALE: NSScrollView sizes its documentView to intrinsic content
        // size by default. Without pinning the document's width to the clip
        // view, the width-pin chain below has nothing fixed to terminate
        // against and resolves to whatever minimum width the sections happen
        // to need, leaving them squashed against the leading edge. Pinning
        // the document to `contentView.widthAnchor` (the clip view) makes it
        // exactly as wide as the visible scroll area and propagates that
        // width through the section pins.
        documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        // Pin each section's width to the document so sections take full available width.
        var widthPinned: [NSView] = sectionViews
        if let guestAgentSection { widthPinned.append(guestAgentSection.section) }
        widthPinned.append(clipboardSection.section)
        for section in widthPinned {
            section.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -32).isActive = true
        }
        if isReadOnly {
            readOnlyBanner.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -32).isActive = true
        }
        if showInitialBootBanner {
            initialBootBanner.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -32)
                .isActive = true
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        generalSection.startObserving()
        resourcesSection.startObserving()
        storageSection.startObserving()
        removableSection.startObserving()
        sharedSection.startObserving()
        networkSection.startObserving()
        audioSection.startObserving()
        guestAgentSection?.startObserving()
        clipboardSection.startObserving()

        startFileMonitorObservation()

        Task { @MainActor in
            await instance.refreshDiskUsage()
            await fileMonitor.setPaths(externalAttachmentPaths)
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        generalSection.stopObserving()
        resourcesSection.stopObserving()
        storageSection.stopObserving()
        removableSection.stopObserving()
        sharedSection.stopObserving()
        networkSection.stopObserving()
        audioSection.stopObserving()
        guestAgentSection?.stopObserving()
        clipboardSection.stopObserving()

        fileMonitorObservation?.cancel()
        fileMonitorObservation = nil
    }

    // MARK: - Banners

    private func configureReadOnlyBanner() {
        let lockIcon = NSImageView(image: .systemSymbol("lock.fill", accessibilityDescription: ""))
        lockIcon.contentTintColor = .systemOrange

        let label = NSTextField(
            wrappingLabelWithString:
                "Sections marked with a lock icon are locked while the VM is running. "
                + "Stop the VM to change them. Other sections can be edited live."
        )
        label.font = .preferredFont(forTextStyle: .callout)
        label.maximumNumberOfLines = 0
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        readOnlyBanner.setViews([lockIcon, label], in: .leading)
        readOnlyBanner.orientation = .horizontal
        readOnlyBanner.alignment = .top
        readOnlyBanner.spacing = 10
        readOnlyBanner.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        readOnlyBanner.wantsLayer = true
        readOnlyBanner.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.1).cgColor
        readOnlyBanner.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.3).cgColor
        readOnlyBanner.layer?.borderWidth = 1
        readOnlyBanner.layer?.cornerRadius = 8
    }

    private func configureInitialBootBanner() {
        let icon = NSImageView(image: .systemSymbol("sparkles", accessibilityDescription: ""))
        icon.contentTintColor = .systemOrange

        let title = NSTextField(labelWithString: "Initial Boot")
        title.font = .preferredFont(forTextStyle: .headline)

        let subtitle = NSTextField(wrappingLabelWithString: initialBootSubtitle)
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 0

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        initialBootBanner.setViews([icon, textStack], in: .leading)
        initialBootBanner.orientation = .horizontal
        initialBootBanner.alignment = .top
        initialBootBanner.spacing = 12
        initialBootBanner.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        initialBootBanner.wantsLayer = true
        initialBootBanner.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.1).cgColor
        initialBootBanner.layer?.cornerRadius = 8
    }

    private var initialBootSubtitle: String {
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

    // MARK: - File monitor

    private func startFileMonitorObservation() {
        fileMonitorObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.configuration.storageDisks
                _ = self.instance.configuration.removableMedia
            },
            apply: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.fileMonitor.setPaths(self.externalAttachmentPaths)
                }
            }
        )
    }

    private var externalAttachmentPaths: Set<String> {
        var paths: Set<String> = []
        paths.formUnion(storageSection.externalPaths)
        paths.formUnion(removableSection.externalPaths)
        return paths
    }
}
