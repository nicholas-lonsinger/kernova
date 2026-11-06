import AppKit
import ApplicationServices
import Foundation
import KernovaKit
import KernovaLogging
import KernovaSynchronization
import UniformTypeIdentifiers

// The live guest's halves of the drag-out seams: its event stream and drag
// pasteboard for the watcher, the window the catcher puts up, and the drop's
// promises and folder it receives them in.

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

    /// Sizes one folder by walking its tree.
    private let measureFolder: @Sendable (URL) -> Int

    /// Hears each folder watch let go of its folder, on the watch's queue.
    private let watchClosed: @Sendable () -> Void

    init(
        measureFolder: @escaping @Sendable (URL) -> Int = { ClipboardArchive.estimatedByteCount(at: $0) },
        watchClosed: @escaping @Sendable () -> Void = {}
    ) {
        self.measureFolder = measureFolder
        self.watchClosed = watchClosed
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

    func sizeFiles(_ urls: [URL], then completion: @escaping @MainActor @Sendable ([Int?]) -> Void) {
        GuestDragFiles.size(urls, measuringFolders: measureFolder) { sizes in
            MainActorBridge.async { completion(sizes) }
        }
    }

    func watchEntries(
        in folder: URL, _ appeared: @escaping @MainActor @Sendable ([URL]) -> Void
    ) -> GuestDragCancel {
        let stop = GuestDragFiles.watchEntries(in: folder, closed: watchClosed) { urls in
            MainActorBridge.async { appeared(urls) }
        }
        return { stop() }
    }

    func coordinateRead(of url: URL, then granted: @escaping @MainActor @Sendable (GuestDragArrival?) -> Void) {
        GuestDragFiles.coordinateRead(of: url) { arrival in
            MainActorBridge.async { granted(arrival) }
        }
    }
}

/// A drag's file work off the main actor: sizing the dropped files, watching a
/// drop's staging folder, and the coordinated read of each arrival. Each call
/// hands back on a queue of its own, never the main actor.
///
/// Isolated to no actor, as is every closure it hands Dispatch or a file
/// coordinator: a closure formed in a main-actor function and passed where no
/// `@Sendable` is declared, as `setCancelHandler(handler:)`'s is not, is
/// isolated to the main actor, and Swift 6 checks that on entry, trapping
/// (`_dispatch_assert_queue_fail` under `swift_task_isCurrentExecutor`) when
/// Dispatch runs it on its own queue.
enum GuestDragFiles {
    private static let logger = KernovaLogger(subsystem: "app.kernova.macosagent", category: "GuestDragFiles")

    /// The queue coordinated reads are granted on.
    private static let coordination = OperationQueue()

    /// Opens and sizes each of `urls` as a pull would open it — a file by its
    /// size, a folder by `measureFolder` — and hands back their sizes in
    /// order, nil for one that cannot be read.
    static func size(
        _ urls: [URL], measuringFolders measureFolder: @escaping @Sendable (URL) -> Int,
        then completion: @escaping @Sendable ([Int?]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(
                urls.map { url in
                    ClipboardPasteboardReader.resolve(filesAt: [url], sizeOf: measureFolder).representations.first?
                        .byteCount
                })
        }
    }

    /// Lists `folder` again each time a vnode source on it reports a write,
    /// which adding or removing an entry is — one listing per coalesced event,
    /// with no polling — handing `appeared` each entry not hidden by a leading
    /// dot, once, every one already there included, until the returned call
    /// stops it; `closed` hears once the watch has let go of the folder.
    static func watchEntries(
        in folder: URL, closed: @escaping @Sendable () -> Void, _ appeared: @escaping @Sendable ([URL]) -> Void
    ) -> () -> Void {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            logger.log(.error, "Could not watch the promises' folder, errno \(errno, privacy: .public)")
            closed()
            return {}
        }
        let queue = DispatchQueue(label: "app.kernova.macosagent.drag-arrivals")
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: queue)
        let seen = Locked<Set<String>>([])
        let scan: @Sendable () -> Void = {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let new = seen.withLock { seen in
                names.filter { !$0.hasPrefix(".") && seen.insert($0).inserted }.sorted()
            }
            guard !new.isEmpty else { return }
            appeared(new.map { folder.appendingPathComponent($0) })
        }
        source.setEventHandler(handler: scan)
        source.setCancelHandler {
            close(descriptor)
            closed()
        }
        source.resume()
        queue.async(execute: scan)
        return { source.cancel() }
    }

    /// Asks for a coordinated read of `url`, handing `granted` what it holds
    /// once the read is granted, or nil when it is neither a file nor a folder
    /// or the read failed.
    static func coordinateRead(of url: URL, _ granted: @escaping @Sendable (GuestDragArrival?) -> Void) {
        let intent = NSFileAccessIntent.readingIntent(with: url)
        NSFileCoordinator(filePresenter: nil).coordinate(with: [intent], queue: coordination) { error in
            if let error {
                logger.log(.warning, "A coordinated read was refused: \(error.localizedDescription, privacy: .public)")
                return granted(nil)
            }
            let url = URL(fileURLWithPath: intent.url.path)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                granted(GuestDragArrival(url: url, isFolder: true))
            } else if values?.isRegularFile == true {
                granted(GuestDragArrival(url: url, isFolder: false))
            } else {
                granted(nil)
            }
        }
    }
}

/// A delivering drop's promises, read off the drag pasteboard while the drop
/// is under way.
@MainActor
final class GuestDragPasteboardDrop: GuestDragDrop {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "GuestDragCatcher")

    private let pasteboard: NSPasteboard

    /// The drag pasteboard as the Pasteboard Manager sees it, synchronized
    /// with the drag's once, on first use.
    private lazy var manager: Pasteboard? = {
        var created: Pasteboard?
        let status = PasteboardCreate(pasteboard.name.rawValue as CFString, &created)
        guard status == noErr, let created else {
            Self.logger.log(.error, "Could not open the drag pasteboard, status \(status, privacy: .public)")
            return nil
        }
        _ = PasteboardSynchronize(created)
        return created
    }()

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// The Pasteboard Manager's identifier of item `index`, in drag order.
    private func identifier(_ index: Int) -> PasteboardItemID? {
        guard let manager else { return nil }
        var identifier: PasteboardItemID?
        guard PasteboardGetItemIdentifier(manager, CFIndex(index + 1), &identifier) == noErr else { return nil }
        return identifier
    }

    func offersPromisedFileURL(item index: Int) -> Bool {
        guard let manager, let identifier = identifier(index) else { return false }
        var flavors: CFArray?
        guard PasteboardCopyItemFlavors(manager, identifier, &flavors) == noErr,
            let flavors = flavors as? [String]
        else { return false }
        return flavors.contains(kPasteboardTypeFileURLPromise as String)
    }

    func setPasteLocation(_ folder: URL) -> Bool {
        guard let manager else { return false }
        let status = PasteboardSetPasteLocation(manager, folder as CFURL)
        if status != noErr {
            Self.logger.log(.notice, "The drop's paste location was refused, status \(status, privacy: .public)")
        }
        return status == noErr
    }

    func requestPromisedFileURL(item index: Int) -> Bool {
        guard let manager, let identifier = identifier(index) else { return false }
        var data: CFData?
        let status = PasteboardCopyItemFlavorData(
            manager, identifier, kPasteboardTypeFileURLPromise as CFString, &data)
        if status != noErr {
            Self.logger.log(.notice, "The promised file URL could not be read, status \(status, privacy: .public)")
        }
        return status == noErr
    }

    func receivers() -> [any FilePromiseReceiving] {
        pasteboard.filePromiseReceivers
    }

    func items() -> [GuestDragItem]? {
        GuestDraggedItems.items(on: pasteboard)
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

    func show(items: [GuestDragItem]) -> Bool {
        let pointer = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
                ?? NSScreen.main
        else { return false }
        layOut(items: items, over: screen.frame)
        // The agent is never the active app, so only this brings it front.
        panel.orderFrontRegardless()
        return true
    }

    /// Sets the box up for `items` and covers `screenFrame`, leaving the
    /// window where it is in the window order.
    func layOut(items: [GuestDragItem], over screenFrame: NSRect) {
        content.hud.present(items, typeIcon: typeIcon)
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
            items: GuestDraggedItems.items(on: sender.draggingPasteboard))
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
        catcher?.performDragOperation(drop: GuestDragPasteboardDrop(sender.draggingPasteboard)) ?? false
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

    /// Shows `items`: one file as its type's icon and its name, one promise —
    /// which has no name until it is called in — as its promised type's icon
    /// and description, and several as the multiple-documents icon and their
    /// count.
    func present(_ items: [GuestDragItem], typeIcon: @MainActor (UTType) -> NSImage) {
        switch items.first {
        case .file(let url)? where items.count == 1:
            iconView.image = typeIcon(GuestDraggedItems.type(named: url))
            nameLabel.stringValue = url.lastPathComponent
        case .promise(let uti)? where items.count == 1:
            let type = UTType(uti) ?? .data
            iconView.image = typeIcon(type)
            nameLabel.stringValue = type.localizedDescription ?? uti
        default:
            let multiple = NSImage(named: NSImage.multipleDocumentsName)
            if multiple == nil { assertionFailure("No image named \(NSImage.multipleDocumentsName)") }
            iconView.image = multiple
            nameLabel.stringValue = "\(items.count) items"
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
