import AppKit
import Foundation
import KernovaKit
import KernovaLogging

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

    init(catcher: GuestDragCatcher) {
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
        panel.contentView = CatcherView(catcher: catcher, fillAlpha: Self.fillAlpha)
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
    private let fill: NSColor
    private let hud = CatcherHUD()

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

    /// Draws each item of the drag the catcher accepted as its file's icon in
    /// the HUD's icon zone, all items on the one frame, whatever size the
    /// source drew them at.
    ///
    /// `NSDragging.h`: changes made through the enumeration hold only while
    /// the drag is over this destination and are removed when it exits, so
    /// every entry is restyled afresh.
    override func updateDraggingItemsForDrag(_ sender: (any NSDraggingInfo)?) {
        guard let sender, catcher?.holdsDragOnSurface == true else { return }
        layoutSubtreeIfNeeded()
        let frame = convert(hud.iconZone.frame, from: hud)
        // The source's formation would move the items off the frames set here.
        sender.draggingFormation = .none
        sender.enumerateDraggingItems(
            options: [], for: self, classes: [NSURL.self], searchOptions: [.urlReadingFileURLsOnly: true]
        ) { item, _, _ in
            guard let url = item.item as? URL else { return }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let image = NSImage(size: frame.size, flipped: false) { rect in
                icon.draw(in: rect)
                return true
            }
            item.setDraggingFrame(frame, contents: image)
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
    /// The icon zone's size, so the size the catcher draws each dragged
    /// item's icon at: Finder's default icon-view size.
    private static let iconSize = NSSize(width: 64, height: 64)

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
            zone.widthAnchor.constraint(equalToConstant: Self.iconSize.width),
            zone.heightAnchor.constraint(equalToConstant: Self.iconSize.height),
            zone.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            zone.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            zone.centerXAnchor.constraint(equalTo: centerXAnchor),
            zone.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            label.topAnchor.constraint(equalTo: zone.bottomAnchor, constant: 14),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 20),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 208),
            hugging,
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
