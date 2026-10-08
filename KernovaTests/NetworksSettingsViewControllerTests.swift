import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The Settings window's Networks pane: the library's named networks, created,
/// renamed and deleted through the command facade.
@Suite("Networks Settings Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct NetworksSettingsViewControllerTests {
    private let preferences = makeTestPreferences()

    private func makeViewModel(entitled: Bool = true) -> VMLibraryViewModel {
        makeSettingsViewModel(preferences: preferences, entitled: entitled)
    }

    /// The pane as the tab container shows it.
    private func makePane(_ viewModel: VMLibraryViewModel) -> NetworksSettingsViewController {
        let pane = NetworksSettingsViewController(viewModel: viewModel)
        pane.loadViewIfNeeded()
        pane.viewWillAppear()
        return pane
    }

    /// A NAT VM on `membership`.
    @discardableResult
    private func addVM(
        _ name: String, to viewModel: VMLibraryViewModel,
        membership: VMNetworkMembership, mode: VMNetworkMode = .nat
    ) -> VMInstance {
        viewModel.library.registerFixture(name: name) {
            $0.networkEnabled = true
            $0.networkMode = mode
            $0.networkMembership = membership
            $0.macAddress = GuestMACAddress.random()
        }
    }

    private func summary(
        _ name: String, members: [String] = []
    ) -> NetworkSummary {
        NetworkSummary(
            id: UUID(), name: name, kind: .nat,
            members: members.map {
                VMSummary(
                    id: UUID(), name: $0, status: "stopped", ipAddress: .unavailable,
                    heldByAnotherCopy: false)
            })
    }

    // MARK: - Presence

    @Test("A build that can attach named networks creates both kinds, and one that cannot creates none")
    func creatableKindsFollowTheEntitlement() {
        #expect(NetworksSettingsViewController.creatableKinds(.entitled) == [.nat, .hostOnly])
        #expect(NetworksSettingsViewController.creatableKinds(.unentitled).isEmpty)
    }

    @Test("The Settings window shows a Networks tab only in a build that can attach named networks")
    func networksTabFollowsTheEntitlement() {
        for entitled in [true, false] {
            let tabs = SettingsTabViewController(viewModel: makeViewModel(entitled: entitled))
            tabs.loadViewIfNeeded()
            let networks = tabs.tabViewItems.filter {
                $0.viewController is NetworksSettingsViewController
            }
            #expect(networks.count == (entitled ? 1 : 0))
            #expect(networks.first?.label == (entitled ? "Networks" : nil))
        }
    }

    @Test("A network list Kernova can't read shows as unreadable, offers the check, and takes no change")
    func anUnreadableListShowsItsState() throws {
        let scratch = TestScratchDirectory(prefix: "NetworksSettingsUnreadable")
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let fileURL = scratch.url.appendingPathComponent("Networks.json")
        let bytes = Data("not json".utf8)
        try bytes.write(to: fileURL)
        let viewModel = VMLibraryViewModel(
            storageService: MockVMStorageService(), diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(), ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: MockFileSystem(), downloadsDirectory: nil, preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(),
            entitlements: .entitled, networks: VMNetworkDirectory(fileURL: fileURL))
        var checks = 0
        viewModel.onShowConfigCheck = { _ in checks += 1 }

        let pane = makePane(viewModel)

        #expect(pane.isUnreadable)
        #expect(pane.networks.isEmpty)
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) }
        }
        let addRemove = try #require(find(NSSegmentedControl.self, in: pane.view).first)
        #expect(!addRemove.isEnabled(forSegment: 0))
        #expect(!addRemove.isEnabled(forSegment: 1))
        let check = try #require(
            find(NSButton.self, in: pane.view).first { $0.title == "Check Config Files\u{2026}" })
        #expect(check.isHiddenOrHasHiddenAncestor == false)
        check.performClick(nil)
        #expect(checks == 1)

        do {
            try pane.create(name: "Lab", kind: .nat)
            Issue.record("A create over an unreadable list went through")
        } catch let error as CommandError {
            #expect(
                error.message
                    == "Kernova can\u{2019}t read its list of networks. Choose File > Check Config Files\u{2026} to review it."
            )
        }
        #expect(try Data(contentsOf: fileURL) == bytes)
    }

    // MARK: - List

    @Test("The list shows each network's name, mode and the VMs on it")
    func listShowsEachNetwork() throws {
        let viewModel = makeViewModel()
        let lab = try viewModel.networks.create(name: "Lab", kind: .nat, verb: .createNetwork)
        _ = try viewModel.networks.create(name: "Build Farm", kind: .hostOnly, verb: .createNetwork)
        addVM("Alpha", to: viewModel, membership: .network(lab.id))
        addVM("Beta", to: viewModel, membership: .network(lab.id))
        // Naming it, but Bridged: on no network of its.
        addVM("Gamma", to: viewModel, membership: .network(lab.id), mode: .bridged)

        let pane = makePane(viewModel)

        #expect(pane.networks.map(\.name) == ["Build Farm", "Lab"])
        let table = try #require(firstSubview(NSTableView.self, in: pane.view))
        #expect(table.numberOfRows == 2)
        let texts = (0..<table.numberOfColumns).map { column in
            (table.view(atColumn: column, row: 1, makeIfNecessary: true) as? NSTableCellView)?
                .textField?.stringValue
        }
        #expect(texts == ["Lab", "NAT", "Alpha, Beta"])
        let farm = (0..<table.numberOfColumns).map { column in
            (table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView)?
                .textField?.stringValue
        }
        #expect(farm == ["Build Farm", "Host Only", "None"])
    }

    @Test("Revealing a network before the pane appears selects its row, and the appearance keeps it")
    func revealBeforeAppearanceSelectsTheRow() throws {
        let viewModel = makeViewModel()
        _ = try viewModel.networks.create(name: "Build Farm", kind: .hostOnly, verb: .createNetwork)
        let lab = try viewModel.networks.create(name: "Lab", kind: .nat, verb: .createNetwork)
        let pane = NetworksSettingsViewController(viewModel: viewModel)

        pane.reveal(lab.id)
        #expect(pane.selectedNetworkIDForTesting == lab.id)

        pane.viewWillAppear()
        defer { pane.viewDidDisappear() }
        #expect(pane.selectedNetworkIDForTesting == lab.id)

        // A network the library does not list selects nothing new.
        pane.reveal(UUID())
        #expect(pane.selectedNetworkIDForTesting == lab.id)
    }

    @Test("A network created anywhere else appears in the open list")
    func listFollowsTheLibrary() async throws {
        let viewModel = makeViewModel()
        let pane = makePane(viewModel)
        defer { pane.viewDidDisappear() }
        #expect(pane.networks.isEmpty)

        try viewModel.commands.createNetwork(name: "Lab", kind: .nat)

        // The list repaints from its observation loop, a main-actor task the
        // create enqueued.
        await drainMainQueue()
        #expect(pane.networks.map(\.name) == ["Lab"])
    }

    // MARK: - Changes

    @Test("Create lists the network in the chosen mode")
    func createListsTheNetwork() throws {
        let viewModel = makeViewModel()
        let pane = makePane(viewModel)

        try pane.create(name: "Lab", kind: .hostOnly)

        #expect(viewModel.networks.state.listed?.map(\.name) == ["Lab"])
        #expect(viewModel.networks.state.listed?.first?.kind == .hostOnly)
        #expect(pane.networks.map(\.name) == ["Lab"])
    }

    @Test("A name another network has is refused, and nothing is listed")
    func duplicateNameIsRefused() throws {
        let viewModel = makeViewModel()
        let pane = makePane(viewModel)
        try pane.create(name: "Lab", kind: .nat)

        #expect(throws: CommandError.self) { try pane.create(name: "lab", kind: .hostOnly) }
        #expect(pane.networks.count == 1)
    }

    @Test("Rename renames the network, and a refused name changes nothing")
    func renameRenamesTheNetwork() throws {
        let viewModel = makeViewModel()
        let pane = makePane(viewModel)
        try pane.create(name: "Lab", kind: .nat)
        let id = try #require(pane.networks.first?.id)

        try pane.rename(id, to: "Staging")
        #expect(pane.networks.map(\.name) == ["Staging"])

        #expect(throws: CommandError.self) { try pane.rename(id, to: "  ") }
        #expect(viewModel.networks.state.listed?.map(\.name) == ["Staging"])
    }

    @Test("Delete stops listing the network and moves each VM on it to a network of its own")
    func deleteMovesMembersToTheirOwnNetworks() throws {
        let viewModel = makeViewModel()
        let pane = makePane(viewModel)
        try pane.create(name: "Lab", kind: .nat)
        let id = try #require(pane.networks.first?.id)
        let member = addVM("Alpha", to: viewModel, membership: .network(id))
        let bystander = addVM("Beta", to: viewModel, membership: .common)

        try pane.delete(id)

        #expect(pane.networks.isEmpty)
        #expect(member.configuration.networkMembership == .isolated)
        #expect(bystander.configuration.networkMembership == .common)
    }

    // MARK: - Copy

    @Test("The members column names each VM, or None")
    func membersText() {
        #expect(NetworksSettingsViewController.membersText([]) == "None")
        #expect(
            NetworksSettingsViewController.membersText(summary("Lab", members: ["A", "B"]).members)
                == "A, B")
    }

    @Test("Delete asks first, naming the VMs it moves, with the destructive button on no key")
    func deleteConfirmationNamesTheMembers() {
        let empty = NetworksSettingsViewController.deleteConfirmation(for: summary("Lab")) {}
        #expect(empty.title == "Delete \u{201C}Lab\u{201D}?")
        #expect(empty.message == "No virtual machine is on this network.")
        #expect(empty.buttons.map(\.title) == ["Delete", "Cancel"])
        #expect(empty.buttons.map(\.role) == [.destructive, .cancel])

        let one = NetworksSettingsViewController.deleteConfirmation(
            for: summary("Lab", members: ["Alpha"])
        ) {}
        #expect(one.message == "\u{201C}Alpha\u{201D} moves to a network of its own.")

        let two = NetworksSettingsViewController.deleteConfirmation(
            for: summary("Lab", members: ["Alpha", "Beta"])
        ) {}
        #expect(
            two.message
                == "\(DataFormatters.quotedList(["Alpha", "Beta"])) each move to a network of their own.")
    }
}
