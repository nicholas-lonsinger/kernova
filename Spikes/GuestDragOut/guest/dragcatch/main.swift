// dragcatch — guest-side helper for the drag-out catcher spike.
//
// Logs the guest's left-button state, each new drag, and every drag-destination
// callback of a small red "CATCH" window. While a guest drag is in progress and
// the pointer has stood still within 80 px of a screen edge for 400 ms, the
// window moves under the pointer — the way a guest agent would place its
// catcher once the host has taken the drag over. The catcher accepts drops as
// .copy and reports the file URLs it received.
//
// Run in the guest from Terminal: /tmp/dragcatch   (Control-C to stop)
// `--selftest` prints the start line and exits without showing anything.

import AppKit

let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()
var logLines: [String] = []

func log(_ text: String) {
    let line = clock.string(from: Date()) + "  " + text
    print(line)
    fflush(stdout)
    logLines.append(line)
    try? (logLines.joined(separator: "\n") + "\n").write(
        toFile: "/tmp/dragcatch.log", atomically: true, encoding: .utf8)
}

func xy(_ p: NSPoint) -> String { "\(Int(p.x.rounded())),\(Int(p.y.rounded()))" }

final class CatcherView: NSView {
    private var updateLogged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL, .URL, .string] + promiseTypes)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.6).setFill()
        bounds.fill()
        ("CATCH" as NSString).draw(
            at: NSPoint(x: 9, y: bounds.midY - 9),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.white]
        )
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateLogged = false
        log(
            "CATCHER draggingEntered  pointer \(xy(NSEvent.mouseLocation))  sourceMask=\(sender.draggingSourceOperationMask.rawValue)"
        )
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if !updateLogged {
            updateLogged = true
            log("CATCHER draggingUpdated (first)  pointer \(xy(NSEvent.mouseLocation))")
        }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        log("CATCHER draggingExited  pointer \(xy(NSEvent.mouseLocation))")
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        log("CATCHER prepareForDragOperation")
        return true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)?.count ?? 0
        log("CATCHER performDragOperation  fileURLs=\(urls.map(\.path))  promises=\(promises)")
        for url in urls {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
            log("CATCHER can read \(url.lastPathComponent)  bytes=\(bytes)")
        }
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        log("CATCHER concludeDragOperation")
    }
}

final class Helper: NSObject, NSApplicationDelegate {
    private let panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = CatcherView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        return panel
    }()

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var buttonDown = NSEvent.pressedMouseButtons & 1 != 0
    private var dragCount = NSPasteboard(name: .drag).changeCount
    private var dragInProgress = false
    private var lastPointer = NSEvent.mouseLocation
    private var stillSince = Date()
    private var armedAt: NSPoint?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let target = "/tmp/drag-me.txt"
        try? "drag-out spike test file\n".write(toFile: target, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func poll() {
        let pointer = NSEvent.mouseLocation
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if down != buttonDown {
            buttonDown = down
            log((down ? "LEFT DOWN" : "LEFT UP  ") + "  at \(xy(pointer))")
            dragInProgress = false
            if !down, armedAt != nil {
                armedAt = nil
                // Leave the catcher up long enough for the drop to be delivered.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [panel] in
                    panel.orderOut(nil)
                    log("catcher hidden")
                }
            }
        }

        let count = dragPasteboard.changeCount
        if count != dragCount {
            dragCount = count
            dragInProgress = buttonDown
            log("DRAG STARTED  at \(xy(pointer))")
        }

        if pointer != lastPointer {
            lastPointer = pointer
            stillSince = Date()
        }

        guard buttonDown, dragInProgress, armedAt != pointer, Date().timeIntervalSince(stillSince) >= 0.4,
            let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let frame = screen.frame
        let nearEdge =
            pointer.x - frame.minX <= 80 || frame.maxX - pointer.x <= 80
            || pointer.y - frame.minY <= 80 || frame.maxY - pointer.y <= 80
        guard nearEdge else { return }
        armedAt = pointer
        panel.setFrameOrigin(NSPoint(x: pointer.x - 32, y: pointer.y - 32))
        panel.orderFrontRegardless()
        log("ARMED catcher under pointer at \(xy(pointer))")
    }
}

let size = NSScreen.main?.frame.size ?? .zero
log(
    "dragcatch start  screen \(Int(size.width))x\(Int(size.height))  LEFT \(NSEvent.pressedMouseButtons & 1 != 0 ? "DOWN" : "UP")  at \(xy(NSEvent.mouseLocation))"
)
if CommandLine.arguments.dropFirst().first == "--selftest" { exit(0) }

let app = NSApplication.shared
let helper = Helper()
app.delegate = helper
app.setActivationPolicy(.accessory)
app.run()
