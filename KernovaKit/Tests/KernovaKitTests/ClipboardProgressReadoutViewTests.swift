import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaAppKitShared
@testable import KernovaKit
@testable import KernovaTransferProgress

/// Unit tests for the transfer readout the status item's dropdown and callout
/// both show.
@Suite("ClipboardProgressReadoutView", .caseScoped)
@MainActor
struct ClipboardProgressReadoutViewTests {
    private func makeSnapshot(isCancellable: Bool, pendingBehind: Int = 0)
        -> ClipboardProgressSnapshot
    {
        ClipboardProgressSnapshot(
            direction: .outbound, peerName: "VM", currentItemName: "a.bin", filesCompleted: 0,
            fileCount: 1, bytesTransferred: 10, totalBytes: 100, bytesPerSecond: nil,
            secondsRemaining: nil, gesture: .paste, elapsedSeconds: 1,
            isCancellable: isCancellable, pendingBehind: pendingBehind)
    }

    @Test("the button is hidden until a cancel handler is installed")
    func hidesTheButtonWithoutAHandler() {
        let view = ClipboardProgressReadoutView(surface: .dropdownItem)
        #expect(view.cancelButtonForTesting.isHidden)

        view.onCancel = {}
        #expect(!view.cancelButtonForTesting.isHidden)

        view.onCancel = nil
        #expect(view.cancelButtonForTesting.isHidden)
    }

    @Test("clicking the button runs the handler installed at click time")
    func clickRunsTheCurrentHandler() {
        let view = ClipboardProgressReadoutView(surface: .dropdownItem)
        var first = 0
        var second = 0
        view.onCancel = { first += 1 }
        view.cancelButtonForTesting.performClick(nil)
        #expect(first == 1)

        // Replaced between two operations: the click must stop the live one.
        view.onCancel = { second += 1 }
        view.cancelButtonForTesting.performClick(nil)
        #expect(first == 1)
        #expect(second == 1)
    }

    @Test(
        "the readout is tall enough for the row that carries the button",
        arguments: [ClipboardProgressReadoutView.Surface.dropdownItem, .callout])
    func measuresWithTheButtonInPlace(surface: ClipboardProgressReadoutView.Surface) {
        // Both surfaces take the height from the frame once, so the measurement
        // has to include a button the first cancellable readout will reveal.
        let view = ClipboardProgressReadoutView(surface: surface)
        let withoutButton = view.fittingSize.height
        view.onCancel = {}
        view.layoutSubtreeIfNeeded()

        #expect(view.frame.height >= withoutButton)
        #expect(view.frame.height >= view.cancelButtonForTesting.fittingSize.height)
    }

    @Test("applying a snapshot renders it without disturbing the handler")
    func applyKeepsTheHandler() {
        let view = ClipboardProgressReadoutView(surface: .dropdownItem)
        view.onCancel = {}
        view.apply(makeSnapshot(isCancellable: true))

        #expect(!view.cancelButtonForTesting.isHidden)
        #expect(view.accessibilityLabel()?.isEmpty == false)
    }

    @Test(
        "the readout says what is queued behind it, and costs no height to say so",
        arguments: [ClipboardProgressReadoutView.Surface.dropdownItem, .callout])
    func rendersWhatIsPendingBehindTheReadout(surface: ClipboardProgressReadoutView.Surface) {
        let view = ClipboardProgressReadoutView(surface: surface)
        let height = view.frame.height

        view.apply(makeSnapshot(isCancellable: true))
        #expect(view.accessibilityLabel()?.contains("pending") == false)

        view.apply(makeSnapshot(isCancellable: true, pendingBehind: 2))
        view.layoutSubtreeIfNeeded()

        #expect(view.accessibilityLabel()?.contains("2 more transfers pending") == true)
        // The surface takes this height once, so the line has to share a row.
        #expect(view.frame.height == height)
    }

    @Test("the bar shows a snapshot applied while the view has no window")
    func barShowsASnapshotAppliedOffScreen() {
        // The status item's dropdown applies snapshots before it opens.
        let view = ClipboardProgressReadoutView(surface: .dropdownItem)
        #expect(view.window == nil)

        view.apply(makeSnapshot(isCancellable: true))

        #expect(view.barFractionForTesting == 0.1)
    }

    @Test("a readout that does not know its bytes fills its bar by files and shows no byte line")
    func unknownBytesShowFilesAlone() {
        let view = ClipboardProgressReadoutView(surface: .dropdownItem)
        view.apply(
            ClipboardProgressSnapshot(
                direction: .inbound, peerName: "VM", currentItemName: "IMG_0001.HEIC", filesCompleted: 250,
                fileCount: 1_000, bytesTransferred: 0, totalBytes: 0, bytesPerSecond: nil,
                secondsRemaining: nil, gesture: .dragOut, elapsedSeconds: 1, bytesKnown: false))
        #expect(view.barFractionForTesting == 0.25)
        #expect(view.byteProgressForTesting.isEmpty)

        view.apply(makeSnapshot(isCancellable: true))
        #expect(view.barFractionForTesting == 0.1)
        #expect(!view.byteProgressForTesting.isEmpty)
    }

    /// A paste of 2 GB, `bytes` of it landed.
    private func pasteSnapshot(bytes: UInt64) -> ClipboardProgressSnapshot {
        ClipboardProgressSnapshot(
            direction: .inbound, peerName: "Mac", currentItemName: "big.bin", filesCompleted: 0, fileCount: 1,
            bytesTransferred: bytes, totalBytes: 2_000_000_000, bytesPerSecond: nil, secondsRemaining: nil,
            gesture: .paste, elapsedSeconds: 1, isCancellable: true)
    }

    /// The share of `bar`'s width its fill presents on screen now, read off its layer's presentation as rendered:
    /// the run of columns, from the leading edge, the color of the leading one.
    private func presentedFill(of bar: NSView) throws -> Double {
        let layer = try #require(bar.layer)
        let scale = 2
        let width = Int(bar.bounds.width) * scale
        let height = Int(bar.bounds.height) * scale
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        (layer.presentation() ?? layer).render(in: context)
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        let row = height / 2
        func pixel(_ x: Int) -> [Int] { (0..<4).map { Int(pixels[(row * width + x) * 4 + $0]) } }
        let painted = (0..<width).filter { pixel($0)[3] > 0 }
        let start = try #require(painted.first)
        let end = try #require(painted.last)
        let fill = pixel(start + scale * 2)
        let filled = (start...end).prefix { x in zip(pixel(x), fill).allSatisfy { abs($0 - $1) <= 24 } }
        return Double(filled.count) / Double(end - start + 1)
    }

    @Test("the bar shows the share of the bytes its text shows as both are applied, after a readout that ended full")
    func barShowsWhatItsTextShows() throws {
        // The status item keeps one readout for every operation it shows.
        let view = ClipboardProgressReadoutView(surface: .callout)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.apply(pasteSnapshot(bytes: 2_000_000_000))
        window.displayIfNeeded()
        CATransaction.flush()

        view.apply(pasteSnapshot(bytes: 433_800_000))
        window.displayIfNeeded()
        CATransaction.flush()

        #expect(view.byteProgressForTesting == "433.8 MB of 2 GB")
        // 433.8 MB of 2 GB, worked by hand: 0.2169.
        let shown = try presentedFill(of: view.barForTesting)
        #expect(abs(shown - 0.2169) < 0.02, "the bar shows \(shown)")
    }

    @Test("Cancel acts on the click that also activates its app")
    func cancelTakesTheFirstClick() {
        // The guest agent is never the active app, so a Cancel that only
        // activated it would let the transfer run on.
        let view = ClipboardProgressReadoutView(surface: .callout)
        #expect(view.cancelButtonForTesting.acceptsFirstMouse(for: nil))
    }
}
