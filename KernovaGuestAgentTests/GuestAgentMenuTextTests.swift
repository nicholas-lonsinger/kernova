import Testing

import KernovaProtocol

@Suite("GuestAgentMenuText")
struct GuestAgentMenuTextTests {
    // MARK: - versionLine

    @Test("versionLine: unknown update shows no suffix")
    func versionUnknown() {
        #expect(
            GuestAgentMenuText.versionLine(version: "0.23.0", build: "42", update: .unknown)
                == "Version 0.23.0 (42)")
    }

    @Test("versionLine: up to date")
    func versionUpToDate() {
        #expect(
            GuestAgentMenuText.versionLine(version: "0.23.0", build: "42", update: .upToDate)
                == "Version 0.23.0 (42) · Up to date")
    }

    @Test("versionLine: update available names the host version")
    func versionUpdateAvailable() {
        #expect(
            GuestAgentMenuText.versionLine(
                version: "0.22.0", build: "40", update: .updateAvailable(bundled: "0.23.0"))
                == "Version 0.22.0 (40) · Update available (host has 0.23.0)")
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
