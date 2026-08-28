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

    @Test("A category row narrower than its content squeezes the accessories, not the facts")
    func narrowCategoryRowKeepsTheFactsLine() throws {
        let header = VMIdentityHeaderView()
        // The panel chrome the Network category hands over, built to hold its
        // width against a section title.
        let hint = makeGroupedFormLockHint()
        header.configure(
            with: makeInstance(), mode: .category("Network"), trailingAccessories: [hint])
        // Narrower than the row's content: the detail pane at its minimum, less
        // the form's margins.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 60))
        container.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.layoutSubtreeIfNeeded()

        let hintLabel = try #require(findLabel(withText: groupedFormLockHintText, in: hint))
        let factsLabel = try #require(findLabel(withText: header.renderedFactsLine, in: header))
        // The hint gives up the width the row is short, truncating its tail…
        #expect(hintLabel.frame.width < hintLabel.intrinsicContentSize.width)
        #expect(hintLabel.lineBreakMode == .byTruncatingTail)
        // …and the VM's live state stays whole.
        #expect(factsLabel.frame.width >= factsLabel.intrinsicContentSize.width - 0.5)
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
