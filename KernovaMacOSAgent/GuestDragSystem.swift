import AppKit
import Foundation
import KernovaKit
import KernovaLogging
import UniformTypeIdentifiers

// The live guest's halves of the drag-out seams: its event stream and drag
// pasteboard for the watcher, and the window the catcher puts up.

/// The guest's own input, read the way an unprivileged accessory app can.
///
/// A global monitor needs no Accessibility permission for mouse events
/// (`NSEvent.h`), and every pasteboard but the general one allows programmatic
/// reads without asking (`NSPasteboard.h`, macOS 15.4+).
@MainActor
final class SystemGuestDragInput: GuestDragInput {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "GuestDragWatcher")

    let dragPasteboard: any ClipboardReadPasteboard = NSPasteboard(name: .drag)

    /// Sizes one folder by walking its tree — the only read of a folder's
    /// contents a drag makes before the host pulls it.
    private let measureFolder: @Sendable (URL) -> Int

    init(measureFolder: @escaping @Sendable (URL) -> Int = { ClipboardArchive.estimatedByteCount(at: $0) }) {
        self.measureFolder = measureFolder
    }

    var isPrimaryButtonHeld: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    func observePrimaryPresses(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> GuestDragCancel {
        // AppKit calls a global monitor's handler on the main thread.
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            MainActor.assumeIsolated { handler() }
        }
        guard let monitor else {
            Self.logger.log(.error, "Could not install the press monitor; no drag will be offered")
            return {}
        }
        return { NSEvent.removeMonitor(monitor) }
    }

    func repeatEvery(
        _ interval: TimeInterval, _ tick: @escaping @MainActor @Sendable () -> Void
    ) -> GuestDragCancel {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            // The main run loop fires this on the main thread.
            MainActor.assumeIsolated { tick() }
        }
        // Common modes, so a press another app tracks in a nested loop is still
        // read on time.
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    func holdActivity(reason: String) -> GuestDragCancel {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: reason)
        return { ProcessInfo.processInfo.endActivity(activity) }
    }

    func resolveFiles(
        _ urls: [URL],
        then completion: @escaping @MainActor @Sendable (ClipboardPasteboardReader.FileIntake) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let intake = ClipboardPasteboardReader.resolve(filesAt: urls, sizeOf: nil)
            MainActorBridge.async { completion(intake) }
        }
    }

    func measureFolders(
        _ folders: [Int: URL], then completion: @escaping @MainActor @Sendable ([Int: Int]) -> Void
    ) {
        let measureFolder = measureFolder
        DispatchQueue.global(qos: .userInitiated).async {
            let sizes = folders.mapValues(measureFolder)
            MainActorBridge.async { completion(sizes) }
        }
    }
}

/// The catcher's window: borderless, never activating the agent, above every
/// app window on all spaces, and covering the screen under the pointer.
@MainActor
final class GuestDragCatcherPanel: GuestDragCatcherSurface {
    /// The fill's alpha: faint but not zero, since no AppKit header says
    /// whether a drag targets a window through fully clear pixels.
    private static let fillAlpha: CGFloat = 0.02

    private let panel: NSPanel

    private let content: CatcherView

    private let typeIcon: @MainActor (UTType) -> NSImage

    init(
        catcher: GuestDragCatcher,
        typeIcon: @escaping @MainActor (UTType) -> NSImage = { NSWorkspace.shared.icon(for: $0) }
    ) {
        self.typeIcon = typeIcon
        content = CatcherView(catcher: catcher, fillAlpha: Self.fillAlpha)
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = content
    }

    #if DEBUG
    /// Test seam: the catcher's window, never ordered front by a test.
    var windowForTesting: NSPanel { panel }
    #endif

    func show(fileURLs: [URL]) -> Bool {
        let pointer = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
                ?? NSScreen.main
        else { return false }
        layOut(fileURLs: fileURLs, over: screen.frame)
        // The agent is never the active app, so only this brings it front.
        panel.orderFrontRegardless()
        return true
    }

    /// Sets the box up for `fileURLs` and covers `screenFrame`, leaving the
    /// window where it is in the window order.
    func layOut(fileURLs: [URL], over screenFrame: NSRect) {
        content.hud.present(fileURLs, typeIcon: typeIcon)
        panel.setFrame(screenFrame, display: true)
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// The catcher window's content: the drag destination, forwarding each
/// callback to the catcher, and the HUD's owner.
private final class CatcherView: NSView {
    private weak var catcher: GuestDragCatcher?
    private let fill: NSColor
    let hud = CatcherHUD()

    init(catcher: GuestDragCatcher, fillAlpha: CGFloat) {
        self.catcher = catcher
        fill = NSColor.white.withAlphaComponent(fillAlpha)
        super.init(frame: .zero)
        hud.install(in: self)
        registerForDraggedTypes(
            [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Takes the first click too: the agent is never the active app, and a
    // click that reaches this view is the one sign left that the surface
    // outlived its drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        catcher?.surfaceClicked()
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        dirtyRect.fill()
    }

    private func drag(_ sender: any NSDraggingInfo) -> GuestDragCatcher.Drag {
        GuestDragCatcher.Drag(
            sourceMask: sender.draggingSourceOperationMask,
            fileURLs: GuestDraggedFiles.fileURLs(on: sender.draggingPasteboard))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        catcher?.draggingEntered(drag(sender)) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        catcher?.draggingUpdated(drag(sender)) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        catcher?.draggingExited()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        catcher?.performDragOperation() ?? false
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        catcher?.concludeDragOperation()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        catcher?.draggingEnded()
    }
}

/// The "Copy to Mac" box, at the screen's center.
///
/// The host holds the guest pointer, and with it the drag image its source
/// draws, by the edge the drag left the VM's display by; the box sits at the
/// center. Decoration only: no point in it takes a hit test, so the whole
/// screen stays the catcher's drag destination and click target.
private final class CatcherHUD: NSVisualEffectView {
    private static let padding: CGFloat = 24
    private static let iconSide: CGFloat = 128
    private static let nameWidthLimit: CGFloat = 272

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    /// Adds the box to `content`, at `content`'s center.
    func install(in content: NSView) {
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "Copy to Mac")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        let rows: [NSView] = [iconView, title, nameLabel]
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
        }
        content.addSubview(self)

        let hugging = widthAnchor.constraint(equalToConstant: 0)
        hugging.priority = .defaultLow
        NSLayoutConstraint.activate(
            [
                centerXAnchor.constraint(equalTo: content.centerXAnchor),
                centerYAnchor.constraint(equalTo: content.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: Self.iconSide),
                iconView.heightAnchor.constraint(equalToConstant: Self.iconSide),
                iconView.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
                title.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
                nameLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
                nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.nameWidthLimit),
                bottomAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: Self.padding),
                hugging,
            ]
                + rows.flatMap { row in
                    [
                        row.centerXAnchor.constraint(equalTo: centerXAnchor),
                        row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.padding),
                    ]
                })
    }

    /// Shows `fileURLs`: one item as its type's icon and its name, several
    /// as the multiple-documents icon and their count.
    ///
    /// The type comes from the item's name alone: a read of a file in a
    /// protected folder raises the guest's privacy prompt, which the
    /// transfer itself never needs.
    func present(_ fileURLs: [URL], typeIcon: @MainActor (UTType) -> NSImage) {
        if fileURLs.count == 1, let item = fileURLs.first {
            iconView.image = typeIcon(Self.type(named: item))
            nameLabel.stringValue = item.lastPathComponent
        } else {
            let multiple = NSImage(named: NSImage.multipleDocumentsName)
            if multiple == nil { assertionFailure("No image named \(NSImage.multipleDocumentsName)") }
            iconView.image = multiple
            nameLabel.stringValue = "\(fileURLs.count) items"
        }
    }

    /// The type `url`'s text names, never asking the file: a URL ending in a
    /// slash, as a drag pasteboard writes a directory's, is a package its
    /// extension names or else a folder, and anything else is the type of
    /// its extension.
    static func type(named url: URL) -> UTType {
        let pathExtension = url.pathExtension
        if url.hasDirectoryPath {
            guard !pathExtension.isEmpty,
                let package = UTType(filenameExtension: pathExtension, conformingTo: .package)
            else { return .folder }
            return package
        }
        guard !pathExtension.isEmpty else { return .data }
        return UTType(filenameExtension: pathExtension) ?? .data
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
