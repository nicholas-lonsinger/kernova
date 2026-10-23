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

    /// The guest's icon for a type, at the drag image's icon size.
    static let workspaceTypeIcon: @MainActor (UTType) -> NSImage = { type in
        let icon = NSWorkspace.shared.icon(for: type)
        let sized = icon.copy() as? NSImage ?? icon
        sized.size = CatcherDragImage.iconSize
        return sized
    }

    init(catcher: GuestDragCatcher, typeIcon: @escaping @MainActor (UTType) -> NSImage = workspaceTypeIcon) {
        content = CatcherView(catcher: catcher, typeIcon: typeIcon, fillAlpha: Self.fillAlpha)
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
        // The agent is never the active app, so only this brings it front.
        panel.orderFrontRegardless()
        return true
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// The catcher window's content: the drag destination, forwarding each
/// callback to the catcher, and the HUD's owner.
private final class CatcherView: NSView {
    private weak var catcher: GuestDragCatcher?
    private let typeIcon: @MainActor (UTType) -> NSImage
    private let fill: NSColor
    private let hud = CatcherHUD()

    init(catcher: GuestDragCatcher, typeIcon: @escaping @MainActor (UTType) -> NSImage, fillAlpha: CGFloat) {
        self.catcher = catcher
        self.typeIcon = typeIcon
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
        let drag = drag(sender)
        let operation = catcher?.draggingEntered(drag) ?? []
        // The pointer is parked on the HUD from the first callback, so the
        // source's image is replaced at once rather than when AppKit asks.
        restyle(sender, drag)
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        catcher?.draggingUpdated(drag(sender)) ?? []
    }

    override func updateDraggingItemsForDrag(_ sender: (any NSDraggingInfo)?) {
        guard let sender else { return }
        restyle(sender, drag(sender))
    }

    /// Draws every item of the taken drag as the first item's
    /// ``CatcherDragImage``, all on one frame centered on the HUD's icon zone,
    /// whatever the source's image, layout, or grab offset — so the items
    /// stack as one — whenever the surface is up for that drag, over it yet
    /// or not.
    ///
    /// The image comes from the items' names alone: a read of a file in a
    /// protected folder raises the guest's privacy prompt, which the
    /// transfer itself never needs.
    ///
    /// `NSDragging.h`: a destination "may change the dragging images at any
    /// time", and changes made through the enumeration hold only while the
    /// drag is over it and are removed when it exits, so every entry restyles
    /// afresh.
    private func restyle(_ sender: any NSDraggingInfo, _ drag: GuestDragCatcher.Drag) {
        guard let urls = catcher?.shownFileURLs, drag.fileURLs == urls, let lead = urls.first else { return }
        layoutSubtreeIfNeeded()
        let zone = convert(hud.iconZone.frame, from: hud)
        let image = CatcherDragImage(
            icon: typeIcon(CatcherDragImage.type(named: lead)), name: lead.lastPathComponent)
        let frame = image.frame(centeredOn: zone)
        let leadComponents = image.components
        let stackedComponents = image.iconComponents
        // The source's formation would move the items off the frames set here.
        sender.draggingFormation = .none
        sender.enumerateDraggingItems(
            options: [], for: self, classes: [NSURL.self], searchOptions: [.urlReadingFileURLsOnly: true]
        ) { item, index, _ in
            let components = index == 0 ? leadComponents : stackedComponents
            item.draggingFrame = frame
            item.imageComponentsProvider = { components }
        }
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
            zone.widthAnchor.constraint(equalToConstant: CatcherDragImage.largestSize.width),
            zone.heightAnchor.constraint(equalToConstant: CatcherDragImage.largestSize.height),
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

/// The image the catcher draws the taken drag as, the way Finder's icon view
/// draws a file: its type's large icon, its name in a pill centered below.
@MainActor
private struct CatcherDragImage {
    /// The square the icon fits in.
    static let iconSize = NSSize(width: 128, height: 128)

    /// The largest image: the widest name pill, under the icon square.
    static let largestSize = NSSize(width: 200, height: iconSize.height + labelGap + labelHeight)

    private static let labelGap: CGFloat = 4
    private static let labelHeight: CGFloat = 18
    private static let labelPadding: CGFloat = 6
    private static let font = NSFont.systemFont(ofSize: 12)
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.alternateSelectedControlTextColor,
    ]

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

    private let icon: NSImage
    private let name: String
    private let textWidth: CGFloat

    init(icon: NSImage, name: String) {
        self.icon = icon
        self.name = name
        textWidth = min(
            ceil((name as NSString).size(withAttributes: Self.attributes).width),
            Self.largestSize.width - 2 * Self.labelPadding)
    }

    private var pill: NSSize { NSSize(width: textWidth + 2 * Self.labelPadding, height: Self.labelHeight) }

    /// The icon square over the name pill, as wide as the wider of the two.
    var size: NSSize { NSSize(width: max(Self.iconSize.width, pill.width), height: Self.largestSize.height) }

    /// The image's frame with its center on `zone`'s, in `zone`'s coordinates.
    func frame(centeredOn zone: NSRect) -> NSRect {
        NSRect(
            x: zone.midX - size.width / 2, y: zone.midY - size.height / 2, width: size.width,
            height: size.height)
    }

    /// The icon fitted and centered in the icon square at the top, in the
    /// image's own bounds — all a stacked item below the first draws.
    var iconComponents: [NSDraggingImageComponent] {
        let square = NSRect(
            x: (size.width - Self.iconSize.width) / 2, y: size.height - Self.iconSize.height,
            width: Self.iconSize.width, height: Self.iconSize.height)
        let scale = min(
            square.width / max(icon.size.width, 1), square.height / max(icon.size.height, 1))
        let fitted = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
        let component = NSDraggingImageComponent(key: .icon)
        component.frame = NSRect(
            x: square.midX - fitted.width / 2, y: square.midY - fitted.height / 2,
            width: fitted.width, height: fitted.height)
        component.contents = icon
        return [component]
    }

    /// The icon over its name's pill, centered below it.
    var components: [NSDraggingImageComponent] {
        let pill = pill
        let label = NSDraggingImageComponent(key: .label)
        label.frame = NSRect(origin: NSPoint(x: (size.width - pill.width) / 2, y: 0), size: pill)
        let (name, textWidth, padding) = (name, textWidth, Self.labelPadding)
        let (font, attributes) = (Self.font, Self.attributes)
        label.contents = NSImage(size: pill, flipped: false) { rect in
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingMiddle
            var drawn = attributes
            drawn[.paragraphStyle] = paragraph
            let line = ceil(font.ascender - font.descender)
            (name as NSString).draw(
                in: NSRect(x: padding, y: (rect.height - line) / 2, width: textWidth, height: line),
                withAttributes: drawn)
            return true
        }
        return iconComponents + [label]
    }
}
