import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The one poll of a pasteboard in a process, which every observer of its change count shares.
@Suite("Clipboard pasteboard watch", .caseScoped)
@MainActor
struct ClipboardPasteboardWatchTests {
    @Test("One watch serves every observer of a pasteboard, standing writes first, then readers in the order they came")
    func oneWatchInTurnOrder() {
        let pasteboard = FakePasteboard()
        var heard: [String] = []
        let passthrough = ClipboardPasteboardWatch.observe(pasteboard, in: .newCopies) { heard.append("passthrough") }
        let write = ClipboardPasteboardWatch.observe(pasteboard, in: .standingWrites) { heard.append("write") }
        let agent = ClipboardPasteboardWatch.observe(pasteboard, in: .newCopies) { heard.append("agent") }
        #expect(ClipboardPasteboardWatch.isPollingForTesting(pasteboard))

        ClipboardPasteboardWatch.pollForTesting(pasteboard)
        #expect(heard == ["write", "passthrough", "agent"])
        withExtendedLifetime((passthrough, write, agent)) {}
    }

    @Test("A watch polls while anything observes it and stops when the last observer goes, cancelled or let go")
    func stopsWithTheLastObserver() {
        let pasteboard = FakePasteboard()
        var heard: [String] = []
        let first = ClipboardPasteboardWatch.observe(pasteboard, in: .newCopies) { heard.append("first") }
        var second: ClipboardPasteboardWatch.Observation? = ClipboardPasteboardWatch.observe(
            pasteboard, in: .standingWrites
        ) { heard.append("second") }
        #expect(second != nil)

        first.cancel()
        ClipboardPasteboardWatch.pollForTesting(pasteboard)
        #expect(heard == ["second"])
        #expect(ClipboardPasteboardWatch.isPollingForTesting(pasteboard))

        // Its holder going away is the end of observing: nothing has to say so.
        second = nil
        #expect(!ClipboardPasteboardWatch.isPollingForTesting(pasteboard))
        ClipboardPasteboardWatch.pollForTesting(pasteboard)
        #expect(heard == ["second"])
    }

    @Test("An observer an earlier one cancels in the same poll does not hear it")
    func cancelledMidPollIsNotHeard() {
        let pasteboard = FakePasteboard()
        var heard: [String] = []
        var later: ClipboardPasteboardWatch.Observation?
        let earlier = ClipboardPasteboardWatch.observe(pasteboard, in: .standingWrites) {
            heard.append("earlier")
            later?.cancel()
        }
        later = ClipboardPasteboardWatch.observe(pasteboard, in: .newCopies) { heard.append("later") }
        ClipboardPasteboardWatch.pollForTesting(pasteboard)
        #expect(heard == ["earlier"])
        withExtendedLifetime(earlier) {}
    }

    @Test("Each pasteboard has a watch of its own")
    func watchPerPasteboard() {
        let general = FakePasteboard()
        let other = FakePasteboard()
        var heard: [String] = []
        let onGeneral = ClipboardPasteboardWatch.observe(general, in: .newCopies) { heard.append("general") }
        let onOther = ClipboardPasteboardWatch.observe(other, in: .newCopies) { heard.append("other") }
        ClipboardPasteboardWatch.pollForTesting(general)
        #expect(heard == ["general"])
        onGeneral.cancel()
        #expect(!ClipboardPasteboardWatch.isPollingForTesting(general))
        #expect(ClipboardPasteboardWatch.isPollingForTesting(other))
        withExtendedLifetime(onOther) {}
    }
}
