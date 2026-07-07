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

    @Test("clipboardLine for each activity")
    func clipboard() {
        #expect(AgentMenuText.clipboardLine(.enabled) == "Clipboard: enabled")
        #expect(AgentMenuText.clipboardLine(.offeredToHost) == "Clipboard: shared with host")
        #expect(AgentMenuText.clipboardLine(.offeredFromHost) == "Clipboard: shared from host")
        #expect(AgentMenuText.clipboardLine(.sentToHost) == "Clipboard: sent to host")
        #expect(
            AgentMenuText.clipboardLine(.receivedFromHost) == "Clipboard: received from host")
        #expect(AgentMenuText.clipboardLine(.disabled) == "Clipboard: disabled")
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
