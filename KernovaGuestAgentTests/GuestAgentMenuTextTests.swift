import Testing

import KernovaProtocol

@Suite("GuestAgentMenuText")
struct GuestAgentMenuTextTests {
    // MARK: - about

    @Test("about command title")
    func about() {
        #expect(GuestAgentMenuText.about() == "About Kernova Guest Agent")
    }

    // MARK: - updateAvailableLine

    @Test("updateAvailableLine names the host's bundled version")
    func updateAvailable() {
        #expect(
            GuestAgentMenuText.updateAvailableLine(bundled: "0.25.0")
                == "Update available — host bundles 0.25.0")
    }

    // MARK: - hostStatusLine

    @Test("hostStatusLine for each connection state")
    func hostStatus() {
        #expect(GuestAgentMenuText.hostStatusLine(.connecting) == "Connecting to host…")
        #expect(GuestAgentMenuText.hostStatusLine(.connected) == "Connected to host")
        #expect(GuestAgentMenuText.hostStatusLine(.unresponsive) == "Host not responding")
    }

    // MARK: - clipboardLine

    @Test("clipboardLine for each activity")
    func clipboard() {
        #expect(GuestAgentMenuText.clipboardLine(.idle) == "Clipboard: idle")
        #expect(GuestAgentMenuText.clipboardLine(.offeredToHost) == "Clipboard: shared with host")
        #expect(
            GuestAgentMenuText.clipboardLine(.receivedFromHost) == "Clipboard: received from host")
    }
}
