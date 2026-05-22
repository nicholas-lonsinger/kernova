import Foundation
import Testing
@testable import Kernova

@Suite("VMInstance.visibleSidebarAgentStatus")
@MainActor
struct VMInstanceVisibleAgentStatusTests {
    private typealias Compute = VMInstance

    @Test("Linux guests never show the sidebar badge")
    func linuxAlwaysNil() {
        let status = Compute.computeVisibleSidebarAgentStatus(
            guestOS: .linux,
            installState: nil,
            agentStatus: .waiting,
            agentInstallNudgeDismissed: false,
            lastSeenAgentVersion: nil,
            isLiveSession: true
        )
        #expect(status == nil)
    }

    @Test("macOS guests in install (installState != nil) suppress the badge")
    func installInProgressNil() {
        let installState = MacOSInstallState(
            hasDownloadStep: false,
            currentPhase: .installing(progress: 0.5)
        )
        let status = Compute.computeVisibleSidebarAgentStatus(
            guestOS: .macOS,
            installState: installState,
            agentStatus: .waiting,
            agentInstallNudgeDismissed: false,
            lastSeenAgentVersion: nil,
            isLiveSession: true
        )
        #expect(status == nil)
    }

    @Test(".current is always hidden (no news is good news)")
    func currentHidden() {
        let status = Compute.computeVisibleSidebarAgentStatus(
            guestOS: .macOS,
            installState: nil,
            agentStatus: .current(version: "1.0.0"),
            agentInstallNudgeDismissed: false,
            lastSeenAgentVersion: nil,
            isLiveSession: true
        )
        #expect(status == nil)
    }

    @Test(".waiting + nudge dismissed → hidden")
    func waitingDismissedHidden() {
        let status = Compute.computeVisibleSidebarAgentStatus(
            guestOS: .macOS,
            installState: nil,
            agentStatus: .waiting,
            agentInstallNudgeDismissed: true,
            lastSeenAgentVersion: nil,
            isLiveSession: true
        )
        #expect(status == nil)
    }

    @Test("Stopped VM with previously-seen agent: .waiting suppressed")
    func waitingStoppedKnownAgentHidden() {
        let status = Compute.computeVisibleSidebarAgentStatus(
            guestOS: .macOS,
            installState: nil,
            agentStatus: .waiting,
            agentInstallNudgeDismissed: false,
            lastSeenAgentVersion: "1.0.0",
            isLiveSession: false
        )
        #expect(status == nil)
    }

    @Test("Live session .waiting always surfaced, even with previously-seen agent")
    func waitingLiveAlwaysSurfaced() {
        let status = Compute.computeVisibleSidebarAgentStatus(
            guestOS: .macOS,
            installState: nil,
            agentStatus: .waiting,
            agentInstallNudgeDismissed: false,
            lastSeenAgentVersion: "1.0.0",
            isLiveSession: true
        )
        #expect(status == .waiting)
    }

    @Test("Stopped VM, never seen an agent → .waiting surfaced")
    func waitingFreshStoppedSurfaced() {
        let status = Compute.computeVisibleSidebarAgentStatus(
            guestOS: .macOS,
            installState: nil,
            agentStatus: .waiting,
            agentInstallNudgeDismissed: false,
            lastSeenAgentVersion: nil,
            isLiveSession: false
        )
        #expect(status == .waiting)
    }

    @Test(".outdated always surfaces (regardless of live/dismissed/last-seen)")
    func outdatedAlwaysSurfaces() {
        let outdated = AgentStatus.outdated(installed: "0.9", bundled: "1.0")
        for live in [true, false] {
            for dismissed in [true, false] {
                let status = Compute.computeVisibleSidebarAgentStatus(
                    guestOS: .macOS,
                    installState: nil,
                    agentStatus: outdated,
                    agentInstallNudgeDismissed: dismissed,
                    lastSeenAgentVersion: live ? "0.9" : nil,
                    isLiveSession: live
                )
                #expect(status == outdated, "live=\(live) dismissed=\(dismissed)")
            }
        }
    }

    @Test(".expectedMissing surfaces")
    func expectedMissingSurfaces() {
        let s = AgentStatus.expectedMissing(expected: "1.0")
        let status = Compute.computeVisibleSidebarAgentStatus(
            guestOS: .macOS,
            installState: nil,
            agentStatus: s,
            agentInstallNudgeDismissed: true,  // even with nudge dismissed
            lastSeenAgentVersion: "1.0",
            isLiveSession: true
        )
        #expect(status == s)
    }

    @Test(".unresponsive surfaces")
    func unresponsiveSurfaces() {
        let s = AgentStatus.unresponsive(version: "1.0")
        let status = Compute.computeVisibleSidebarAgentStatus(
            guestOS: .macOS,
            installState: nil,
            agentStatus: s,
            agentInstallNudgeDismissed: false,
            lastSeenAgentVersion: "1.0",
            isLiveSession: true
        )
        #expect(status == s)
    }

    @Test(".connecting surfaces")
    func connectingSurfaces() {
        let s = AgentStatus.connecting(expected: "1.0")
        let status = Compute.computeVisibleSidebarAgentStatus(
            guestOS: .macOS,
            installState: nil,
            agentStatus: s,
            agentInstallNudgeDismissed: false,
            lastSeenAgentVersion: "1.0",
            isLiveSession: true
        )
        #expect(status == s)
    }
}
