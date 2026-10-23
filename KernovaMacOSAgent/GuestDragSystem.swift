import AppKit
import Foundation
import KernovaKit
import KernovaLogging
import QuickLookThumbnailing

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

/// A file's QuickLook thumbnail, made off the main thread.
@MainActor
protocol GuestDragThumbnails {
    /// Asks for `url`'s thumbnail to fit `size`; `completion` runs on the main
    /// actor only if one is made, and never after the returned cancel runs.
    func thumbnail(
        of url: URL, fitting size: NSSize, then completion: @escaping @MainActor (NSImage) -> Void
    ) -> GuestDragCancel
}

/// The guest's QuickLook thumbnailer.
@MainActor
struct SystemGuestDragThumbnails: GuestDragThumbnails {
    func thumbnail(
        of url: URL, fitting size: NSSize, then completion: @escaping @MainActor (NSImage) -> Void
    ) -> GuestDragCancel {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        let cancellation = Cancellation()
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.cgImage else { return }
            MainActorBridge.async {
                guard !cancellation.isCancelled else { return }
                completion(NSImage(cgImage: image, size: .zero))
            }
        }
        return {
            cancellation.isCancelled = true
            QLThumbnailGenerator.shared.cancel(request)
        }
    }

    /// Whether the caller cancelled, read where the thumbnail is delivered.
    @MainActor
    private final class Cancellation {
        var isCancelled = false
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

    init(catcher: GuestDragCatcher, thumbnails: any GuestDragThumbnails = SystemGuestDragThumbnails()) {
        content = CatcherView(catcher: catcher, thumbnails: thumbnails, fillAlpha: Self.fillAlpha)
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

    func show() -> Bool {
        let pointer = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
                ?? NSScreen.main
        else { return false }
        panel.setFrame(screen.frame, display: true)
        content.prepareThumbnail()
        // The agent is never the active app, so only this brings it front.
        panel.orderFrontRegardless()
        return true
    }

    func hide() {
        panel.orderOut(nil)
        content.surfaceHidden()
    }
}

/// The catcher window's content: the drag destination, forwarding each
/// callback to the catcher, and the HUD's owner.
private final class CatcherView: NSView {
    private weak var catcher: GuestDragCatcher?
    private let thumbnails: any GuestDragThumbnails
    private let fill: NSColor
    private let hud = CatcherHUD()

    /// The first taken file's thumbnail: asked for once per take, kept
    /// across stand-downs so every showing draws the same image.
    private var thumbnail: (url: URL, image: NSImage?, cancel: GuestDragCancel?)?
    /// The drag over the view, restyled again when the thumbnail arrives.
    private var draggingInfo: (any NSDraggingInfo)?

    init(catcher: GuestDragCatcher, thumbnails: any GuestDragThumbnails, fillAlpha: CGFloat) {
        self.catcher = catcher
        self.thumbnails = thumbnails
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
        let operation = catcher?.draggingEntered(drag(sender)) ?? []
        // The pointer is parked on the HUD from the first callback, so the
        // source's image is replaced at once rather than when AppKit asks.
        restyle(sender)
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        catcher?.draggingUpdated(drag(sender)) ?? []
    }

    override func updateDraggingItemsForDrag(_ sender: (any NSDraggingInfo)?) {
        guard let sender else { return }
        restyle(sender)
    }

    /// Draws every item of the drag the catcher accepted as the first taken
    /// file's ``CatcherDragImage``, all on the HUD's icon zone, whatever the
    /// source's image, layout, or grab offset — so the items stack as one.
    ///
    /// `NSDragging.h`: a destination "may change the dragging images at any
    /// time", and changes made through the enumeration hold only while the
    /// drag is over it and are removed when it exits, so every entry restyles
    /// afresh.
    private func restyle(_ sender: any NSDraggingInfo) {
        guard catcher?.holdsDragOnSurface == true, let first = catcher?.takenFileURLs?.first else { return }
        draggingInfo = sender
        prepareThumbnail()
        layoutSubtreeIfNeeded()
        let frame = convert(hud.iconZone.frame, from: hud)
        let image = thumbnail?.image ?? CatcherDragImage.workspaceIcon(of: first)
        let name = FileManager.default.displayName(atPath: first.path)
        // The source's formation would move the items off the frames set here.
        sender.draggingFormation = .none
        sender.enumerateDraggingItems(
            options: [], for: self, classes: [NSURL.self], searchOptions: [.urlReadingFileURLsOnly: true]
        ) { item, index, _ in
            let components = CatcherDragImage.components(image: image, name: index == 0 ? name : nil)
            item.draggingFrame = frame
            item.imageComponentsProvider = { components }
        }
    }

    /// Asks for the first taken file's thumbnail, unless this take already did.
    func prepareThumbnail() {
        guard let url = catcher?.takenFileURLs?.first, thumbnail?.url != url else { return }
        thumbnail?.cancel?()
        thumbnail = (url, nil, nil)
        let cancel = thumbnails.thumbnail(of: url, fitting: CatcherDragImage.iconSize) { [weak self] image in
            self?.thumbnailArrived(image, for: url)
        }
        if thumbnail?.url == url, thumbnail?.image == nil {
            thumbnail?.cancel = cancel
        }
    }

    private func thumbnailArrived(_ image: NSImage, for url: URL) {
        guard thumbnail?.url == url else { return }
        thumbnail = (url, image, nil)
        if let draggingInfo { restyle(draggingInfo) }
    }

    /// The window went down: the drag is no longer over it, and once the take
    /// is over its thumbnail is no longer wanted.
    func surfaceHidden() {
        draggingInfo = nil
        guard catcher?.takenFileURLs == nil else { return }
        thumbnail?.cancel?()
        thumbnail = nil
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        draggingInfo = nil
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
        draggingInfo = nil
        catcher?.draggingEnded()
    }
}

/// The box behind the guest's drag image saying where the drag is going.
///
/// The host nudges the guest pointer to the screen's center, so the drag image
/// sits there, above every window; the box puts its icon zone on that point
/// and its label below. Decoration only: no point in it takes a hit test, so
/// the whole screen stays the catcher's drag destination and click target.
private final class CatcherHUD: NSVisualEffectView {
    /// The box's inset around its content on every side.
    private static let margin: CGFloat = 24

    /// Where the drag image sits, in the box's coordinates.
    let iconZone = NSLayoutGuide()

    /// Adds the box to `content`, its icon zone centered on `content`'s center.
    func install(in content: NSView) {
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Copy to Mac")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        content.addSubview(self)

        let zone = iconZone
        addLayoutGuide(zone)
        let hugging = widthAnchor.constraint(equalToConstant: 0)
        hugging.priority = .defaultLow
        NSLayoutConstraint.activate([
            zone.widthAnchor.constraint(equalToConstant: CatcherDragImage.size.width),
            zone.heightAnchor.constraint(equalToConstant: CatcherDragImage.size.height),
            zone.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            zone.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            zone.centerXAnchor.constraint(equalTo: centerXAnchor),
            zone.topAnchor.constraint(equalTo: topAnchor, constant: Self.margin),
            label.topAnchor.constraint(equalTo: zone.bottomAnchor, constant: Self.margin),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: Self.margin),
            widthAnchor.constraint(greaterThanOrEqualTo: zone.widthAnchor, constant: 2 * Self.margin),
            hugging,
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The image the catcher draws each dragged item as, the way Finder's icon
/// view draws a file: a large icon or thumbnail, its name in a pill below.
@MainActor
private enum CatcherDragImage {
    /// The square the icon or thumbnail fits in.
    static let iconSize = NSSize(width: 128, height: 128)

    /// The whole image: the widest name pill, over the icon square and the pill.
    static let size = NSSize(width: 200, height: iconSize.height + labelGap + labelHeight)

    private static let labelGap: CGFloat = 4
    private static let labelHeight: CGFloat = 18
    private static let labelPadding: CGFloat = 6
    private static let font = NSFont.systemFont(ofSize: 12)

    /// `url`'s Finder icon, at the icon square's size.
    static func workspaceIcon(of url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = iconSize
        return icon
    }

    /// `image` fitted and centered in the icon square at the top and, given a
    /// name, its pill centered below — in the item's own bounds of ``size``.
    static func components(image: NSImage, name: String?) -> [NSDraggingImageComponent] {
        let square = NSRect(
            x: (size.width - iconSize.width) / 2, y: size.height - iconSize.height,
            width: iconSize.width, height: iconSize.height)
        let scale = min(
            square.width / max(image.size.width, 1), square.height / max(image.size.height, 1))
        let fitted = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let iconComponent = NSDraggingImageComponent(key: .icon)
        iconComponent.frame = NSRect(
            x: square.midX - fitted.width / 2, y: square.midY - fitted.height / 2,
            width: fitted.width, height: fitted.height)
        iconComponent.contents = image
        guard let name else { return [iconComponent] }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.alternateSelectedControlTextColor,
        ]
        let textWidth = min(
            ceil((name as NSString).size(withAttributes: attributes).width), size.width - 2 * labelPadding)
        let pill = NSSize(width: textWidth + 2 * labelPadding, height: labelHeight)
        let labelComponent = NSDraggingImageComponent(key: .label)
        labelComponent.frame = NSRect(origin: NSPoint(x: (size.width - pill.width) / 2, y: 0), size: pill)
        labelComponent.contents = NSImage(size: pill, flipped: false) { rect in
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingMiddle
            var drawn = attributes
            drawn[.paragraphStyle] = paragraph
            let line = ceil(font.ascender - font.descender)
            (name as NSString).draw(
                in: NSRect(x: labelPadding, y: (rect.height - line) / 2, width: textWidth, height: line),
                withAttributes: drawn)
            return true
        }
        return [iconComponent, labelComponent]
    }
}
