import AppKit
import Testing

@testable import Kernova

@Suite("VMIdentityHeaderView Tests")
@MainActor
struct VMIdentityHeaderViewTests {
    private func makeInstance(name: String = "Test VM", cpuCount: Int = 4) -> VMInstance {
        let config = VMConfiguration(
            name: name, guestOS: .macOS, bootMode: .macOS, cpuCount: cpuCount)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    // MARK: - Facts line

    @Test("Every known fact reads in order, separated by interpuncts")
    func factsLineListsEverythingKnown() {
        let line = VMIdentityHeaderView.factsLine(
            status: "Running", osVersion: "26.6", cores: 4, memoryGB: 8,
            diskBytes: 100_000_000_000)

        #expect(
            line == "Running · 26.6 · 4 cores · 8 GB memory · \(DataFormatters.formatBytes(100_000_000_000)) disk"
        )
    }

    @Test("An unreported OS version leaves out the segment rather than a placeholder")
    func factsLineOmitsUnknownOSVersion() {
        let line = VMIdentityHeaderView.factsLine(
            status: "Stopped", osVersion: nil, cores: 2, memoryGB: 4, diskBytes: 64_000_000_000)

        #expect(line == "Stopped · 2 cores · 4 GB memory · \(DataFormatters.formatBytes(64_000_000_000)) disk")
    }

    @Test("An unread disk leaves out the segment")
    func factsLineOmitsUnknownDisk() {
        let line = VMIdentityHeaderView.factsLine(
            status: "Stopped", osVersion: nil, cores: 1, memoryGB: 4, diskBytes: nil)

        #expect(line == "Stopped · 1 core · 4 GB memory")
    }

    // MARK: - Configuration

    @Test("Configuring puts the VM name and its status on screen")
    func configureShowsNameAndStatus() {
        let instance = makeInstance(name: "Ventura Box")
        let header = VMIdentityHeaderView()

        header.configure(with: instance)

        #expect(findLabel(withText: "Ventura Box", in: header) != nil)
        #expect(findLabel(containing: instance.statusDisplayName, in: header) != nil)
    }

    @Test("Re-binding to another VM re-renders from the new one")
    func configureRebindsToAnotherVM() {
        let header = VMIdentityHeaderView()
        header.configure(with: makeInstance(name: "First"))

        header.configure(with: makeInstance(name: "Second", cpuCount: 2))

        #expect(findLabel(withText: "First", in: header) == nil)
        #expect(findLabel(withText: "Second", in: header) != nil)
        #expect(findLabel(containing: "2 cores", in: header) != nil)
    }
}
