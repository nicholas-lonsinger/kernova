// SPIKE — throwaway instrumentation for the guest-to-host drag mouse-up
// question. Never merged.

import Cocoa
import KernovaLogging
import Virtualization

private let spikeLogger = KernovaLogger(subsystem: "app.kernova", category: "DragOutSpike")

@MainActor
private func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

/// A `VZVirtualMachineView` that logs the mouse events it receives before
/// passing them on.
@MainActor
final class DragSpyMachineView: VZVirtualMachineView {
    /// Set by the spike around its own synthetic event.
    var isInjecting = false

    private var draggedCount = 0
    private var firstDragLogged = false
    private var outsideDragLogged = 0

    override func mouseDown(with event: NSEvent) {
        draggedCount = 0
        firstDragLogged = false
        outsideDragLogged = 0
        logEvent("down", event)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        draggedCount += 1
        let point = convert(event.locationInWindow, from: nil)
        let inside = bounds.contains(point)
        if !firstDragLogged {
            firstDragLogged = true
            logEvent("dragged(first)", event)
        } else if !inside, outsideDragLogged < 20 {
            outsideDragLogged += 1
            logEvent("dragged(outside)", event)
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        flushDragCount(at: "mouseUp")
        logEvent("up", event)
        super.mouseUp(with: event)
    }

    /// Logs the mouseDragged events received since the last flush.
    func flushDragCount(at moment: String) {
        #log(
            spikeLogger, .notice,
            "SPIKE view dragged total=\(self.draggedCount, privacy: .public) at=\(moment, privacy: .public)"
        )
        draggedCount = 0
    }

    private func logEvent(_ kind: String, _ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let x = Int(point.x.rounded())
        let y = Int(point.y.rounded())
        let inside = yesNo(bounds.contains(point))
        let synthetic = yesNo(isInjecting)
        #log(
            spikeLogger, .notice,
            "SPIKE view \(kind, privacy: .public) \(x, privacy: .public),\(y, privacy: .public) inside=\(inside, privacy: .public) synthetic=\(synthetic, privacy: .public)"
        )
    }
}

/// Watches a press that starts on the display, starts a host drag session when
/// it leaves the display, and one second later hands the guest a synthetic
/// mouseUp — preceded by a 1-px synthetic drag when the press left through the
/// left edge.
@MainActor
final class DragOutSpike: NSObject, NSDraggingSource {
    private enum Mode: String { case up, wiggle }

    private static let pasteboardType = NSPasteboard.PasteboardType("app.kernova.spike.drag-out")

    private weak var hostView: NSView?
    private let machineView: DragSpyMachineView

    private var monitor: Any?
    private var pollTimer: Timer?
    private var stashedDown: NSEvent?
    private var lastInsidePoint: NSPoint?
    private var sessionStarted = false
    private var mode = Mode.up

    init(hostView: NSView, machineView: DragSpyMachineView) {
        self.hostView = hostView
        self.machineView = machineView
    }

    // MARK: - Window attachment

    func windowChanged(to window: NSWindow?) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        endGesture()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            nonisolated(unsafe) let incoming = event
            nonisolated(unsafe) var outgoing: NSEvent? = incoming
            MainActor.assumeIsolated {
                guard let self else { return }
                outgoing = self.handle(incoming)
            }
            return outgoing
        }
    }

    // MARK: - Monitor

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = machineView.window, event.window === window else { return event }
        let point = machineView.convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            guard machineView.bounds.contains(point) else { return event }
            stashedDown = event
            lastInsidePoint = nil
            sessionStarted = false
            #log(spikeLogger, .notice, "SPIKE monitor down \(Self.xy(point), privacy: .public)")
            startPolling()
            return event
        case .leftMouseDragged:
            guard stashedDown != nil, !sessionStarted else { return event }
            if machineView.bounds.contains(point) {
                lastInsidePoint = point
                return event
            }
            let edge = edge(of: point)
            #log(
                spikeLogger, .notice,
                "SPIKE exit edge=\(edge, privacy: .public) \(Self.xy(point), privacy: .public)"
            )
            startSession(edge: edge)
            return nil
        case .leftMouseUp:
            #log(spikeLogger, .notice, "SPIKE monitor up session=\(yesNo(self.sessionStarted), privacy: .public)")
            stashedDown = nil
            stopPolling()
            return event
        default:
            return event
        }
    }

    // MARK: - Poll fallback

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard stashedDown != nil, !sessionStarted, let window = machineView.window else {
            stopPolling()
            return
        }
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            #log(spikeLogger, .notice, "SPIKE poll saw release")
            stashedDown = nil
            stopPolling()
            return
        }
        let point = machineView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if machineView.bounds.contains(point) {
            lastInsidePoint = point
            return
        }
        let edge = edge(of: point)
        #log(
            spikeLogger, .notice,
            "SPIKE exit (poll) edge=\(edge, privacy: .public) \(Self.xy(point), privacy: .public)"
        )
        startSession(edge: edge)
    }

    // MARK: - Session

    private func startSession(edge: String) {
        guard let hostView, let down = stashedDown else { return }
        sessionStarted = true
        stopPolling()
        machineView.flushDragCount(at: "sessionStart")
        mode = edge == "left" ? .wiggle : .up

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("spike", forType: Self.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let downPoint = hostView.convert(down.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(x: downPoint.x, y: downPoint.y, width: 48, height: 48),
            contents: NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
        )
        #log(spikeLogger, .notice, "SPIKE session begin mode=\(self.mode.rawValue, privacy: .public)")
        hostView.beginDraggingSession(with: [item], event: down, source: self)
        scheduleInjection()
    }

    /// One second after the session begins — long enough for the guest-side
    /// catcher to arm under the frozen guest pointer — injects the release.
    private func scheduleInjection() {
        let mode = self.mode
        let fire = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch mode {
                case .up:
                    self.injectUp(label: "up only")
                    self.endGesture()
                case .wiggle:
                    self.injectDrag()
                    let release = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.injectUp(label: "after wiggle")
                            self.endGesture()
                        }
                    }
                    RunLoop.main.add(release, forMode: .common)
                }
            }
        }
        RunLoop.main.add(fire, forMode: .common)
    }

    private func injectDrag() {
        guard
            let window = machineView.window,
            let base = lastInsidePoint ?? stashedDown.map({ machineView.convert($0.locationInWindow, from: nil) })
        else {
            #log(spikeLogger, .notice, "SPIKE could not build drag event")
            return
        }
        let point = NSPoint(x: base.x + (base.x < machineView.bounds.midX ? 1 : -1), y: base.y)
        guard
            let drag = NSEvent.mouseEvent(
                with: .leftMouseDragged, location: machineView.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1
            )
        else {
            #log(spikeLogger, .notice, "SPIKE could not build drag event")
            return
        }
        lastInsidePoint = point
        machineView.isInjecting = true
        machineView.mouseDragged(with: drag)
        machineView.isInjecting = false
        #log(spikeLogger, .notice, "SPIKE injected drag (wiggle) \(Self.xy(point), privacy: .public)")
    }

    private func injectUp(label: String) {
        guard let window = machineView.window else {
            #log(spikeLogger, .notice, "SPIKE could not build event")
            return
        }
        let point =
            lastInsidePoint
            ?? stashedDown.map { machineView.convert($0.locationInWindow, from: nil) }
            ?? .zero
        guard
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: machineView.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 0
            )
        else {
            #log(spikeLogger, .notice, "SPIKE could not build event")
            return
        }
        machineView.isInjecting = true
        machineView.mouseUp(with: up)
        machineView.isInjecting = false
        #log(
            spikeLogger, .notice,
            "SPIKE injected up (\(label, privacy: .public)) \(Self.xy(point), privacy: .public)"
        )
    }

    private func endGesture() {
        stopPolling()
        stashedDown = nil
        lastInsidePoint = nil
        sessionStarted = false
    }

    // MARK: - NSDraggingSource

    nonisolated func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        let text = Self.xy(screenPoint)
        #log(spikeLogger, .notice, "SPIKE session willBegin screen=\(text, privacy: .public)")
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        let text = Self.xy(screenPoint)
        let op = operation.rawValue
        #log(spikeLogger, .notice, "SPIKE session end op=\(op, privacy: .public) \(text, privacy: .public)")
    }

    // MARK: - Helpers

    nonisolated private static func xy(_ point: NSPoint) -> String {
        "\(Int(point.x.rounded())),\(Int(point.y.rounded()))"
    }

    private func edge(of point: NSPoint) -> String {
        let bounds = machineView.bounds
        if point.x < bounds.minX { return "left" }
        if point.x > bounds.maxX { return "right" }
        let belowMinY = point.y < bounds.minY
        if machineView.isFlipped {
            return belowMinY ? "top" : "bottom"
        }
        return belowMinY ? "bottom" : "top"
    }
}
