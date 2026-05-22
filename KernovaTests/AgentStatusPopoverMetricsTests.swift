import Foundation
import Testing
@testable import Kernova

@Suite("AgentStatusPopoverMetrics Tests")
struct AgentStatusPopoverMetricsTests {
    // MARK: - Titles

    @Test("title for each status is the correct headline")
    func titles() {
        #expect(AgentStatusPopoverMetrics.title(for: .waiting) == "Set up the Kernova guest agent")
        #expect(
            AgentStatusPopoverMetrics.title(for: .outdated(installed: "1", bundled: "2"))
                == "Update available"
        )
        #expect(
            AgentStatusPopoverMetrics.title(for: .connecting(expected: "1"))
                == "Connecting to guest agent"
        )
        #expect(
            AgentStatusPopoverMetrics.title(for: .current(version: "1")) == "Guest agent connected"
        )
        #expect(
            AgentStatusPopoverMetrics.title(for: .unresponsive(version: "1"))
                == "Guest agent unresponsive"
        )
        #expect(
            AgentStatusPopoverMetrics.title(for: .expectedMissing(expected: "1"))
                == "Guest agent didn't reconnect"
        )
    }

    // MARK: - Body text interpolates vmName + versions

    @Test("body text for .waiting interpolates vmName")
    func bodyWaiting() {
        let body = AgentStatusPopoverMetrics.bodyText(for: .waiting, vmName: "Sequoia Dev")
        #expect(body.contains("Sequoia Dev"))
        #expect(body.contains("install.command"))
    }

    @Test("body text for .outdated interpolates installed + bundled + vmName")
    func bodyOutdated() {
        let body = AgentStatusPopoverMetrics.bodyText(
            for: .outdated(installed: "0.9.1", bundled: "1.0.0"),
            vmName: "Sequoia Dev"
        )
        #expect(body.contains("Sequoia Dev"))
        #expect(body.contains("0.9.1"))
        #expect(body.contains("1.0.0"))
    }

    @Test("body text for .connecting interpolates expected version")
    func bodyConnecting() {
        let body = AgentStatusPopoverMetrics.bodyText(
            for: .connecting(expected: "1.0.0"), vmName: "Sequoia Dev")
        #expect(body.contains("Sequoia Dev"))
        #expect(body.contains("1.0.0"))
        #expect(body.contains("reconnect"))
    }

    @Test("body text for .current interpolates version + vmName")
    func bodyCurrent() {
        let body = AgentStatusPopoverMetrics.bodyText(
            for: .current(version: "1.0.0"), vmName: "Sequoia Dev")
        #expect(body.contains("Sequoia Dev"))
        #expect(body.contains("1.0.0"))
    }

    @Test("body text for .unresponsive interpolates version + vmName")
    func bodyUnresponsive() {
        let body = AgentStatusPopoverMetrics.bodyText(
            for: .unresponsive(version: "1.0.0"), vmName: "Sequoia Dev")
        #expect(body.contains("Sequoia Dev"))
        #expect(body.contains("1.0.0"))
        #expect(body.contains("heartbeat"))
    }

    @Test("body text for .expectedMissing interpolates expected version")
    func bodyExpectedMissing() {
        let body = AgentStatusPopoverMetrics.bodyText(
            for: .expectedMissing(expected: "1.0.0"),
            vmName: "Sequoia Dev"
        )
        #expect(body.contains("Sequoia Dev"))
        #expect(body.contains("1.0.0"))
        #expect(body.contains("Reinstalling"))
    }

    // MARK: - Action button titles

    @Test("actionButtonTitle reflects per-status action verbs")
    func actionTitles() {
        #expect(AgentStatusPopoverMetrics.actionButtonTitle(for: .waiting) == "Install Guest Agent\u{2026}")
        #expect(
            AgentStatusPopoverMetrics.actionButtonTitle(for: .outdated(installed: "1", bundled: "2"))
                == "Update Guest Agent\u{2026}"
        )
        #expect(
            AgentStatusPopoverMetrics.actionButtonTitle(for: .expectedMissing(expected: "1"))
                == "Reinstall Guest Agent\u{2026}"
        )
        // "Done" for the no-op cases
        #expect(AgentStatusPopoverMetrics.actionButtonTitle(for: .current(version: "1")) == "Done")
        #expect(AgentStatusPopoverMetrics.actionButtonTitle(for: .unresponsive(version: "1")) == "Done")
        #expect(AgentStatusPopoverMetrics.actionButtonTitle(for: .connecting(expected: "1")) == "Done")
    }
}
