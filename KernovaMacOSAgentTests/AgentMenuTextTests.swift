import KernovaKit
import Testing

@Suite("AgentMenuText")
struct AgentMenuTextTests {
    // MARK: - about

    @Test("about command title")
    func about() {
        #expect(AgentMenuText.about() == "About Kernova Guest Agent")
    }

    // MARK: - updateAvailableLine

    @Test("updateAvailableLine names the host's bundled version")
    func updateAvailable() {
        #expect(
            AgentMenuText.updateAvailableLine(bundled: "0.25.0")
                == "Update available — host bundles 0.25.0")
    }

    // MARK: - hostStatusLine

    @Test("hostStatusLine for each connection state")
    func hostStatus() {
        #expect(AgentMenuText.hostStatusLine(.connecting) == "Connecting to host…")
        #expect(AgentMenuText.hostStatusLine(.connected) == "Connected to host")
        #expect(AgentMenuText.hostStatusLine(.unresponsive) == "Host not responding")
    }

    // MARK: - clipboardLine

    /// The ceiling every non-refusal line ignores.
    private static let limit = ClipboardPasteLimit.defaultBytes

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

    @Test("clipboardLine names every paste failure the guest can report, honestly per code")
    func clipboardRefusalLines() {
        let limit = Self.limit
        // The over-cap sentence is built from the ceiling, not typed.
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.pasteTooLarge, pasteLimitBytes: limit))
                == "Clipboard: too large to paste — over the \(ClipboardPasteLimit.displayLimit(limit)) transfer limit"
        )
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.pasteDiskFull, pasteLimitBytes: limit))
                == "Clipboard: not enough disk space to paste")
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.pasteTimeout, pasteLimitBytes: limit))
                == "Clipboard: paste timed out")
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.pasteFailed, pasteLimitBytes: limit))
                == "Clipboard: paste failed")
        // Host-only refusals never reach the guest; they read as the generic
        // failure rather than a sentence about a gesture made elsewhere.
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.copyTooLarge, pasteLimitBytes: limit))
                == "Clipboard: paste failed")
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.pasteIncompleteSet, pasteLimitBytes: limit))
                == "Clipboard: paste failed")
    }

    @Test("the over-cap line names the ceiling the refusal carries, not a current one")
    func clipboardRefusalNamesTheCarriedCeiling() {
        let raised = 16 * 1024 * 1024 * 1024
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.pasteTooLarge, pasteLimitBytes: raised))
                == "Clipboard: too large to paste — over the 16 GB transfer limit")
    }

    @Test("an over-cap refusal with no carried ceiling names none rather than inventing one")
    func clipboardRefusalWithoutACeilingNamesNone() {
        // The menu rebuilds on every open, so the figure has to come from the
        // refusal itself; absent one, the line says only what it knows.
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.pasteTooLarge, pasteLimitBytes: nil))
                == "Clipboard: too large to paste")
    }

    @Test("a copy that crossed short names what was left out and what fixes it")
    func clipboardCopyShortenedLines() {
        #expect(
            AgentMenuText.clipboardLine(.copyShortened(offeringAnything: true))
                == "Clipboard: shared without folders — Kernova on the Mac needs updating")
        #expect(
            AgentMenuText.clipboardLine(.copyShortened(offeringAnything: false))
                == "Clipboard: folders not shared — Kernova on the Mac needs updating")
    }

    @Test("a copy that carried nothing says so rather than naming a cause it can't know")
    func clipboardCopyCarriedNothingLine() {
        // Unreadable items, an all-filtered flavor set and a pasteboard whose
        // every item is already staged all reach this line, so it names the
        // outcome the user can see and no reason it would have to guess at.
        #expect(
            AgentMenuText.clipboardLine(.copyCarriedNothing)
                == "Clipboard: nothing in that copy could be shared")
    }

    // MARK: - isNotice

    @Test("Only the outcomes of a gesture made in this guest reveal themselves")
    func noticeActivities() {
        #expect(ClipboardActivity.pasteRefused(.pasteFailed, pasteLimitBytes: nil).isNotice)
        #expect(ClipboardActivity.copyShortened(offeringAnything: true).isNotice)
        #expect(ClipboardActivity.copyShortened(offeringAnything: false).isNotice)
        #expect(ClipboardActivity.copyCarriedNothing.isNotice)
        for activity: ClipboardActivity in [
            .enabled, .offeredToHost, .offeredFromHost, .sentToHost, .receivedFromHost, .disabled,
        ] {
            #expect(!activity.isNotice, "\(activity) must not open the dropdown by itself")
        }
    }

    // MARK: - logForwardingLine / statusSubmenu

    @Test("logForwardingLine reflects the enabled flag")
    func logForwarding() {
        #expect(AgentMenuText.logForwardingLine(true) == "Log Forwarding: enabled")
        #expect(AgentMenuText.logForwardingLine(false) == "Log Forwarding: disabled")
    }

    @Test("statusSubmenu title")
    func statusSubmenuTitle() {
        #expect(AgentMenuText.statusSubmenu() == "Status")
    }
}
