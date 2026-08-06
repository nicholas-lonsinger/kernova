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
        let limit = Self.limit
        #expect(AgentMenuText.clipboardLine(.enabled, pasteLimitBytes: limit) == "Clipboard: enabled")
        #expect(
            AgentMenuText.clipboardLine(.offeredToHost, pasteLimitBytes: limit)
                == "Clipboard: shared with host")
        #expect(
            AgentMenuText.clipboardLine(.offeredFromHost, pasteLimitBytes: limit)
                == "Clipboard: shared from host")
        #expect(
            AgentMenuText.clipboardLine(.sentToHost, pasteLimitBytes: limit)
                == "Clipboard: sent to host")
        #expect(
            AgentMenuText.clipboardLine(.receivedFromHost, pasteLimitBytes: limit)
                == "Clipboard: received from host")
        #expect(
            AgentMenuText.clipboardLine(.disabled, pasteLimitBytes: limit) == "Clipboard: disabled")
    }

    @Test("clipboardLine names every paste failure the guest can report, honestly per code")
    func clipboardRefusalLines() {
        let limit = Self.limit
        // The over-cap sentence is built from the ceiling, not typed.
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.pasteTooLarge), pasteLimitBytes: limit)
                == "Clipboard: too large to paste — over the \(ClipboardPasteLimit.displayLimit(limit)) transfer limit"
        )
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.pasteDiskFull), pasteLimitBytes: limit)
                == "Clipboard: not enough disk space to paste")
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.pasteTimeout), pasteLimitBytes: limit)
                == "Clipboard: paste timed out")
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.pasteFailed), pasteLimitBytes: limit)
                == "Clipboard: paste failed")
        // Host-only refusals never reach the guest; they read as the generic
        // failure rather than a sentence about a gesture made elsewhere.
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.copyTooLarge), pasteLimitBytes: limit)
                == "Clipboard: paste failed")
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.pasteIncompleteSet), pasteLimitBytes: limit)
                == "Clipboard: paste failed")
    }

    @Test("the over-cap line names the ceiling the agent was pushed, not the default")
    func clipboardRefusalNamesThePushedCeiling() {
        let raised = 16 * 1024 * 1024 * 1024
        #expect(
            AgentMenuText.clipboardLine(.pasteRefused(.pasteTooLarge), pasteLimitBytes: raised)
                == "Clipboard: too large to paste — over the 16 GB transfer limit")
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
