// PromiseProbe: a drop target that calls in file promises and times what
// AppKit reports. For each drop it logs the pasteboard items and their types,
// each NSFilePromiseReceiver's fileTypes and fileNames, then times — from the
// call-in — when fileNames fills in, when files appear in the destination
// folder, and when each reader callback fires.
//
// Spike for issue #1626; never shipped. Build with build.sh.

import AppKit

private let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes)

private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private func offset(_ start: UInt64, _ end: UInt64) -> String {
    String(format: "+%.1f ms", Double(end &- start) / 1_000_000)
}

private func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// The size of a regular file, or -1 for a folder or an unreadable item.
private func fileSize(_ url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
    guard values?.isDirectory != true, let size = values?.fileSize else { return -1 }
    return Int64(size)
}

private let wallClock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

// MARK: - Log

/// Everything the probe reports, shown in the window and appended to
/// ~/Library/Logs/PromiseProbe.log (a folder no privacy prompt guards).
final class ProbeLog {
    let fileURL: URL
    private(set) var text = ""
    var onChange: (() -> Void)?

    init() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("PromiseProbe.log")
    }

    func add(_ line: String) {
        text += line + "\n"
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
        onChange?()
    }

    func clear() {
        text = ""
        onChange?()
    }
}

// MARK: - One drop

/// Calls in one drop's promises and watches them until every receiver has
/// reported what it names, then logs a summary.
final class DropSession {
    let number: Int
    let source: String
    let folder: URL
    let receivers: [NSFilePromiseReceiver]
    let itemCount: Int
    let plainFileItems: Int

    private let log: ProbeLog
    private let onFinished: (DropSession) -> Void
    private let readerQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private var start: UInt64 = 0
    private var names: [[String]]
    private var firstNameAt: [String?]
    private var namedAtCallIn: [Bool]
    private var reads: [[String]]
    private var seenFiles: [(name: String, at: String)] = []
    private var timer: DispatchSourceTimer?
    private var lastEvent: UInt64 = 0
    private var isFinished = false

    init(
        number: Int, source: String, folder: URL, receivers: [NSFilePromiseReceiver],
        itemCount: Int, plainFileItems: Int, log: ProbeLog,
        onFinished: @escaping (DropSession) -> Void
    ) {
        self.number = number
        self.source = source
        self.folder = folder
        self.receivers = receivers
        self.itemCount = itemCount
        self.plainFileItems = plainFileItems
        self.log = log
        self.onFinished = onFinished
        names = Array(repeating: [], count: receivers.count)
        firstNameAt = Array(repeating: nil, count: receivers.count)
        namedAtCallIn = Array(repeating: false, count: receivers.count)
        reads = Array(repeating: [], count: receivers.count)
    }

    func begin() {
        start = now()
        for (index, receiver) in receivers.enumerated() {
            let called = now()
            receiver.receivePromisedFiles(
                atDestination: folder, options: [:], operationQueue: readerQueue
            ) { [weak self] url, error in
                let at = now()
                let size = fileSize(url)
                DispatchQueue.main.async {
                    self?.read(index, url: url, error: error, at: at, size: size)
                }
            }
            let returned = now()
            let named = receiver.fileNames
            if !named.isEmpty {
                names[index] = named
                namedAtCallIn[index] = true
                firstNameAt[index] = offset(start, returned)
            }
            log.add(
                "  r\(index) call-in returned \(offset(start, returned)) (call took \(offset(called, returned))) · fileNames \(named)"
            )
        }
        lastEvent = now()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    /// Every 2 ms: a change to any receiver's fileNames, or a new entry in the
    /// destination folder.
    private func poll() {
        guard !isFinished else { return }
        let at = now()
        for (index, receiver) in receivers.enumerated() {
            let current = receiver.fileNames
            guard current != names[index] else { continue }
            names[index] = current
            if firstNameAt[index] == nil, !current.isEmpty { firstNameAt[index] = offset(start, at) }
            log.add("  \(offset(start, at))  r\(index) fileNames → \(current)")
            lastEvent = at
        }
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])) ?? []
        for entry in entries where !seenFiles.contains(where: { $0.name == entry.lastPathComponent }) {
            let stamp = offset(start, at)
            seenFiles.append((entry.lastPathComponent, stamp))
            let size = fileSize(entry)
            log.add(
                "  \(stamp)  file appeared: \(entry.lastPathComponent) (\(size >= 0 ? byteString(size) + " so far" : "folder"))"
            )
            lastEvent = at
        }
        let everyoneRead = receivers.indices.allSatisfy { reads[$0].count >= max(1, names[$0].count) }
        let quiet = Double(at &- lastEvent) / 1e9
        let elapsed = Double(at &- start) / 1e9
        if (everyoneRead && quiet >= 1.5) || elapsed >= 300 {
            finish(timedOut: !everyoneRead)
        }
    }

    private func read(_ index: Int, url: URL, error: Error?, at: UInt64, size: Int64) {
        guard !isFinished else {
            log.add("  (after summary \(number)) r\(index) reader: \(url.lastPathComponent) error \(String(describing: error))")
            return
        }
        lastEvent = now()
        let namesThen = receivers[index].fileNames
        if let error = error as NSError? {
            reads[index].append("error at \(offset(start, at))")
            log.add(
                "  \(offset(start, at))  r\(index) reader ERROR \(error.domain) \(error.code): \(error.localizedDescription)"
            )
        } else {
            reads[index].append("\(url.lastPathComponent) at \(offset(start, at))")
            log.add(
                "  \(offset(start, at))  r\(index) reader: \(url.lastPathComponent) \(size >= 0 ? byteString(size) : "folder") · fileNames then \(namesThen)"
            )
        }
    }

    private func finish(timedOut: Bool) {
        isFinished = true
        timer?.cancel()
        timer = nil
        let declared = receivers.reduce(0) { $0 + $1.fileTypes.count }
        let readCount = reads.reduce(0) { $0 + $1.count }
        var header =
            "SUMMARY \(number) · \(source) · \(itemCount) pasteboard item(s) · \(receivers.count) promise receiver(s) · \(declared) file type(s) declared · \(readCount) reader callback(s)"
        if plainFileItems > 0 { header += " · \(plainFileItems) plain file item(s)" }
        if timedOut { header += " · TIMED OUT after 300 s" }
        log.add(header)
        for (index, receiver) in receivers.enumerated() {
            log.add(
                "  r\(index) types \(receiver.fileTypes) · first name \(firstNameAt[index] ?? "never") (right after call-in: \(namedAtCallIn[index] ? "yes" : "no")) · reads \(reads[index].isEmpty ? "none" : reads[index].joined(separator: "; "))"
            )
        }
        if !seenFiles.isEmpty {
            log.add("  files seen in the folder: " + seenFiles.map { "\($0.name) \($0.at)" }.joined(separator: "; "))
        }
        log.add("")
        onFinished(self)
    }
}

// MARK: - Window

/// The drop area: accepts promises and file URLs, answering copy.
final class DropView: NSView {
    var onEnter: (() -> Void)?
    var onDrop: ((NSDraggingInfo) -> Bool)?
    private var highlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(promiseTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = true
        onEnter?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }

    override func draggingEnded(_ sender: NSDraggingInfo) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        return onDrop?(sender) ?? false
    }

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.insetBy(dx: 12, dy: 12)
        let path = NSBezierPath(roundedRect: area, xRadius: 14, yRadius: 14)
        (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.textBackgroundColor).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 3
        path.setLineDash([10, 6], count: 2, phase: 0)
        path.stroke()

        let title = "Drop Photos, Mail or Safari items here" as NSString
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ]
        let titleSize = title.size(withAttributes: titleAttributes)
        title.draw(
            at: NSPoint(x: bounds.midX - titleSize.width / 2, y: bounds.midY + 2), withAttributes: titleAttributes)

        let note = "Each drop adds a DROP block and a SUMMARY below. Log file: ~/Library/Logs/PromiseProbe.log" as NSString
        let noteAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let noteSize = note.size(withAttributes: noteAttributes)
        note.draw(
            at: NSPoint(x: bounds.midX - noteSize.width / 2, y: bounds.midY - noteSize.height - 8),
            withAttributes: noteAttributes)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var textView: NSTextView!
    private let log = ProbeLog()
    private var sessions: [DropSession] = []
    private var dropCount = 0
    private var enteredSource = "unknown"
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PromiseProbe-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 980, height: 700)
        window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "PromiseProbe"
        let content = NSView(frame: frame)
        window.contentView = content

        let drop = DropView(frame: .zero)
        drop.translatesAutoresizingMaskIntoConstraints = false
        // During a drag the source app stays frontmost, so this names it.
        drop.onEnter = { [weak self] in
            self?.enteredSource = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        }
        drop.onDrop = { [weak self] info in self?.dropped(info) ?? false }

        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView = scroll.documentView as? NSTextView
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        let copy = NSButton(title: "Copy All", target: self, action: #selector(copyAll))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        let buttons = NSStackView(views: [copy, clear])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(drop)
        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            drop.topAnchor.constraint(equalTo: content.topAnchor),
            drop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            drop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            drop.heightAnchor.constraint(equalToConstant: 170),
            scroll.topAnchor.constraint(equalTo: drop.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        log.onChange = { [weak self] in self?.refresh() }
        log.add("PromiseProbe started \(wallClock.string(from: Date())) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log.add("")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func refresh() {
        textView.string = log.text
        textView.scrollToEndOfDocument(nil)
    }

    private func dropped(_ info: NSDraggingInfo) -> Bool {
        dropCount += 1
        let number = dropCount
        let pasteboard = info.draggingPasteboard
        let items = pasteboard.pasteboardItems ?? []
        log.add(
            "DROP \(number) · source \(enteredSource) · \(wallClock.string(from: Date())) · source mask \(info.draggingSourceOperationMask.rawValue) · \(items.count) pasteboard item(s)"
        )
        var plainFileItems = 0
        for (index, item) in items.enumerated() {
            let types = item.types.map(\.rawValue)
            let isPromise = !promiseTypes.isDisjoint(with: types)
            let fileName = item.string(forType: .fileURL).flatMap { URL(string: $0) }?.lastPathComponent
            if !isPromise, fileName != nil { plainFileItems += 1 }
            log.add(
                "  item \(index): promise \(isPromise ? "yes" : "no")\(fileName.map { " · file URL \($0)" } ?? "") · types \(types.joined(separator: ", "))"
            )
        }
        let receivers =
            (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
                as? [NSFilePromiseReceiver]) ?? []
        for (index, receiver) in receivers.enumerated() {
            log.add("  r\(index) before call-in · fileTypes \(receiver.fileTypes) · fileNames \(receiver.fileNames)")
        }
        guard !receivers.isEmpty else {
            log.add("SUMMARY \(number) · \(enteredSource) · no promises · \(plainFileItems) plain file item(s)")
            log.add("")
            return plainFileItems > 0
        }
        let folder = root.appendingPathComponent("drop-\(number)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = DropSession(
            number: number, source: enteredSource, folder: folder, receivers: receivers,
            itemCount: items.count, plainFileItems: plainFileItems, log: log
        ) { [weak self] finished in
            self?.sessions.removeAll { $0 === finished }
        }
        sessions.append(session)
        session.begin()
        return true
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.text, forType: .string)
    }

    @objc private func clearLog() {
        log.clear()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
