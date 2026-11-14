import KernovaAgentCore
import KernovaKit
import KernovaTestSupport
import Testing

@Suite("AgentMenuText", .caseScoped)
struct AgentMenuTextTests {
    // MARK: - hostStatusLine

    @Test("hostStatusLine for each connection state")
    func hostStatus() {
        #expect(AgentMenuText.hostStatusLine(.connecting) == "Connecting to host…")
        #expect(AgentMenuText.hostStatusLine(.connected) == "Connected to host")
        #expect(AgentMenuText.hostStatusLine(.unresponsive) == "Host not responding")
    }

    // MARK: - clipboardLine

    @Test("clipboardLine for each activity")
    func clipboard() {
        #expect(AgentMenuText.clipboardLine(.enabled) == "Clipboard: enabled")
        #expect(
            AgentMenuText.clipboardLine(.offeredToHost)
                == "Clipboard: shared with host")
        #expect(
            AgentMenuText.clipboardLine(.offeredFromHost)
                == "Clipboard: shared from host")
        #expect(
            AgentMenuText.clipboardLine(.sentToHost)
                == "Clipboard: sent to host")
        #expect(
            AgentMenuText.clipboardLine(.receivedFromHost)
                == "Clipboard: received from host")
        #expect(
            AgentMenuText.clipboardLine(.disabled) == "Clipboard: disabled")
    }

    @Test("an over-cap refusal with no carried ceiling names none rather than inventing one")
    func clipboardRefusalWithoutACeilingNamesNone() {
        // The menu rebuilds on every open, so the figure has to come from the
        // refusal itself; absent one, the line says only what it knows.
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.pasteTooLarge, pasteLimitBytes: nil))
                == "Clipboard: too large to paste")
    }

    @Test("a copy that partly crossed names how many items it did not carry whole")
    func clipboardCopyPartlyCarriedLine() {
        // The host's readout covers what the offer carried, so the count is
        // named here or nowhere.
        #expect(
            AgentMenuText.clipboardLine(.copyPartlyCarried(skipped: 1))
                == "Clipboard: shared with host — 1 item not in full")
        #expect(
            AgentMenuText.clipboardLine(.copyPartlyCarried(skipped: 3))
                == "Clipboard: shared with host — 3 items not in full")
    }

    @Test("a copy the Mac withdrew says the Mac withdrew it, and what of it went")
    func clipboardCopyWithdrawnLine() {
        #expect(
            AgentMenuText.clipboardLine(.copyWithdrawn(filesOnly: false))
                == "Clipboard: the Mac withdrew its copy, so it was removed")
        #expect(
            AgentMenuText.clipboardLine(.copyWithdrawn(filesOnly: true))
                == "Clipboard: the Mac withdrew its copy, so its files were removed; the rest is still here")
    }

    // MARK: - isNotice

    @Test("Only the outcomes of a gesture made in this guest, and a copy the Mac withdrew, reveal themselves")
    func noticeActivities() {
        #expect(ClipboardActivity.pasteRefused(.pasteFailed, pasteLimitBytes: nil).isNotice)
        #expect(ClipboardActivity.copyCarriedNothing.isNotice)
        #expect(ClipboardActivity.copyPartlyCarried(skipped: 1).isNotice)
        #expect(ClipboardActivity.copyWithdrawn(filesOnly: false).isNotice)
        for activity: ClipboardActivity in [
            .enabled, .offeredToHost, .offeredFromHost, .sentToHost, .receivedFromHost, .disabled,
        ] {
            #expect(!activity.isNotice, "\(activity) must not be announced by itself")
        }
    }

    // MARK: - logForwardingLine / statusSubmenu

    @Test("logForwardingLine reflects the enabled flag")
    func logForwarding() {
        #expect(AgentMenuText.logForwardingLine(true) == "Log Forwarding: enabled")
        #expect(AgentMenuText.logForwardingLine(false) == "Log Forwarding: disabled")
    }
}
