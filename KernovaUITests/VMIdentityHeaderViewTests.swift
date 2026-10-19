import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

@Suite("VMIdentityHeaderView Tests", .caseScoped)
@MainActor
struct VMIdentityHeaderViewTests {
    private func makeInstance(name: String = "Test VM", cpuCount: Int = 4) -> VMInstance {
        VMInstanceFixture.make(name: name, guestOS: .macOS) { $0.cpuCount = cpuCount }
    }

    // MARK: - Facts line

    @Test("Every known fact reads in order, separated by interpuncts")
    func factsLineListsEverythingKnown() {
        let line = VMIdentityHeaderView.factsLine(
            status: "Running", osVersion: "26.6", cores: 4, memory: .gibibytes(8), disks: 2)

        #expect(line == "Running · 26.6 · 4 cores · 8 GB memory · 2 disks")
    }

    @Test("An unreported OS version leaves out the segment rather than a placeholder")
    func factsLineOmitsUnknownOSVersion() {
        let line = VMIdentityHeaderView.factsLine(
            status: "Stopped", osVersion: nil, cores: 1, memory: .gibibytes(4), disks: 1)

        #expect(line == "Stopped · 1 core · 4 GB memory · 1 disk")
    }

    @Test("The facts line counts every disk the VM attaches, an installer ahead of the main disk included")
    func factsLineCountsTheConfiguredDisks() {
        let instance = VMInstanceFixture.make(guestOS: .linux) {
            $0.cpuCount = 4
            $0.storageDisks = [
                StorageDisk(path: "/tmp/ubuntu-26.04.1-desktop-arm64.iso"),
                StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true),
            ]
        }
        let header = VMIdentityHeaderView()

        header.configure(with: instance)

        #expect(header.renderedFactsLine.hasSuffix(" · 2 disks"))
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

    @Test("A category hosts its panel's affordances beside the title it states")
    func categoryHostsPanelAccessories() throws {
        let header = VMIdentityHeaderView()
        // The panel chrome the Network category hands over.
        let hint = makeGroupedFormLockHint()
        header.configure(
            with: makeInstance(), mode: .category("Network"), trailingAccessories: [hint])
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 60))
        container.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.layoutSubtreeIfNeeded()

        let title = try #require(findLabel(withText: "Network", in: header))
        let factsLabel = try #require(findLabel(withText: header.renderedFactsLine, in: header))
        #expect(hint.isDescendant(of: header))
        // The facts line keeps its own row below the title, as it does on the
        // overview — the accessories share the title's row instead.
        let titleFrame = title.convert(title.bounds, to: header)
        let factsFrame = factsLabel.convert(factsLabel.bounds, to: header)
        let hintFrame = hint.convert(hint.bounds, to: header)
        #expect(factsFrame.maxY <= titleFrame.minY)
        #expect(hintFrame.midY > titleFrame.minY)
        #expect(hintFrame.midY < titleFrame.maxY)
        // A trailing accessory sits at the header's far edge, not crowded up
        // against the title.
        #expect(hintFrame.maxX >= header.bounds.maxX - 1)
        #expect(hintFrame.minX > titleFrame.maxX)
    }

    @Test("A category row narrower than its content squeezes the accessories, not the title")
    func narrowCategoryRowKeepsTheTitle() throws {
        let header = VMIdentityHeaderView()
        // The panel chrome the Network category hands over, built to hold its
        // width against a section title.
        let hint = makeGroupedFormLockHint()
        header.configure(
            with: makeInstance(), mode: .category("Network"), trailingAccessories: [hint])
        // Narrower than the title row's content — the tile, the category's name
        // and the hint together — so something has to give.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        container.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.layoutSubtreeIfNeeded()

        let hintLabel = try #require(findLabel(withText: groupedFormLockHintText, in: hint))
        let title = try #require(findLabel(withText: "Network", in: header))
        // The hint gives up the width the row is short, truncating its tail…
        #expect(hintLabel.frame.width < hintLabel.intrinsicContentSize.width)
        #expect(hintLabel.lineBreakMode == .byTruncatingTail)
        // …and the name of what the header states stays whole.
        #expect(title.frame.width >= title.intrinsicContentSize.width - 0.5)
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
