import Testing
import AppKit
@testable import Kernova

@Suite("SheetPresenter Tests")
@MainActor
struct SheetPresenterTests {
    @Test("endSheet resumes a present(_:on:) await with the supplied response")
    func endSheetReturnsResponse() async {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        parent.makeKeyAndOrderFront(nil)

        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))

        async let response = SheetPresenter.present(content, on: parent)

        // Yield so the sheet has time to be attached before we end it.
        for _ in 0..<5 { await Task.yield() }

        if let sheet = parent.attachedSheet {
            SheetPresenter.endSheet(sheet, returnCode: .OK)
        }

        let actual = await response
        #expect(actual == .OK)
    }

    @Test("OpenPanelOutcome cases match expected discriminants")
    func openPanelOutcomeCases() {
        let cancelled = SheetPresenter.OpenPanelOutcome.cancelled
        let selected = SheetPresenter.OpenPanelOutcome.selected([
            URL(fileURLWithPath: "/tmp/a"),
            URL(fileURLWithPath: "/tmp/b"),
        ])
        switch cancelled {
        case .cancelled: break
        case .selected: Issue.record("Expected .cancelled")
        }
        if case let .selected(urls) = selected {
            #expect(urls.count == 2)
        } else {
            Issue.record("Expected .selected")
        }
    }

    @Test("SavePanelOutcome cases match expected discriminants")
    func savePanelOutcomeCases() {
        let cancelled = SheetPresenter.SavePanelOutcome.cancelled
        let selected = SheetPresenter.SavePanelOutcome.selected(URL(fileURLWithPath: "/tmp/x"))
        switch cancelled {
        case .cancelled: break
        case .selected: Issue.record("Expected .cancelled")
        }
        if case let .selected(url) = selected {
            #expect(url.lastPathComponent == "x")
        } else {
            Issue.record("Expected .selected")
        }
    }
}
