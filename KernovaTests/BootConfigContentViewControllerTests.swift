import AppKit
import Testing

@testable import Kernova

@Suite("BootConfigContentViewController Tests")
@MainActor
struct BootConfigContentViewControllerTests {
    @Test("EFI mode offers all three image sources, with none picked to start")
    func efiShowsEveryImageSource() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(firstSubview(NSSegmentedControl.self, in: vc.view)?.selectedSegment == 0)
        #expect(findButton(titled: "Choose a Distribution…", in: vc.view)?.state == .off)
        #expect(findButton(titled: "Image URL…", in: vc.view)?.state == .off)
        #expect(findButton(titled: "ISO File…", in: vc.view)?.state == .off)
        #expect(findLabel(withText: "Kernel", in: vc.view) == nil)
    }

    @Test("A verified URL pick lights its radio and names the file, size and verification")
    func verifiedURLPickRendersBadge() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectLinuxCustomURL(
            makeResolvedLinuxImage(
                isoURLString: "https://mirror.example/alpine-3.22-aarch64.iso",
                filename: "alpine-3.22-aarch64.iso", sha256: String(repeating: "a", count: 64),
                sizeBytes: 1_073_741_824))
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findButton(titled: "Image URL…", in: vc.view)?.state == .on)
        #expect(findButton(titled: "Choose a Distribution…", in: vc.view)?.state == .off)
        #expect(
            findLabel(
                containing:
                    "alpine-3.22-aarch64.iso  ·  \(DataFormatters.formatBytes(1_073_741_824))  ·  Verified with your checksum",
                in: vc.view) != nil)
        #expect(findLabel(containing: "won't be verified", in: vc.view) == nil)
        #expect(findButton(titled: "Change…", in: vc.view) != nil)
    }

    @Test("An unverified URL pick says so on the badge and in a banner")
    func unverifiedURLPickWarns() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectLinuxCustomURL(
            makeResolvedLinuxImage(
                isoURLString: "https://mirror.example/alpine-3.22-aarch64.iso",
                filename: "alpine-3.22-aarch64.iso", sha256: nil))
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(containing: "Not verified", in: vc.view) != nil)
        #expect(
            findLabel(
                containing: "This download won't be verified. Choose a host you trust.",
                in: vc.view) != nil)
    }

    @Test("A catalog pick lights its radio and names the image on a badge")
    func catalogPickRendersBadge() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectLinuxCatalogEntry(
            makeLinuxCatalogEntry(
                distribution: "Ubuntu Desktop", version: "26.04 LTS",
                approxSizeBytes: 4_161_089_536))
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findButton(titled: "Choose a Distribution…", in: vc.view)?.state == .on)
        #expect(findButton(titled: "ISO File…", in: vc.view)?.state == .off)
        #expect(
            findLabel(
                containing: "Ubuntu Desktop  ·  26.04 LTS  ·  \(wizardApproximateSize(4_161_089_536))",
                in: vc.view) != nil)
        #expect(findButton(titled: "Change…", in: vc.view) != nil)
    }

    @Test("A local ISO lights its radio and shows the file path")
    func localISORendersPathBadge() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectLocalISO(path: "/tmp/ubuntu.iso", bookmark: nil)
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findButton(titled: "ISO File…", in: vc.view)?.state == .on)
        #expect(findButton(titled: "Choose a Distribution…", in: vc.view)?.state == .off)
        #expect(findLabel(withText: "/tmp/ubuntu.iso", in: vc.view) != nil)
    }

    @Test("Clicking a source radio commits nothing until the picker returns")
    func radioClickAloneCommitsNothing() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        // Standing in for a cancelled picker: with no window there is nothing to
        // present onto, so the click gets only the re-render.
        findButton(titled: "Choose a Distribution…", in: vc.view)?.performClick(nil)

        #expect(vm.linuxSelection == nil)
        #expect(findButton(titled: "Choose a Distribution…", in: vc.view)?.state == .off)
    }

    @Test("Choosing from the picker commits the entry and lights its radio")
    func catalogSheetChoiceCommits() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        let entry = makeLinuxCatalogEntry(distribution: "Debian", version: "13")
        vc.linuxImageCatalogSheet(makeCatalogSheet(), didChoose: entry)

        #expect(vm.linuxSelection == .catalogEntry(entry))
        #expect(findButton(titled: "Choose a Distribution…", in: vc.view)?.state == .on)
    }

    @Test("Cancelling the picker leaves the earlier pick standing")
    func catalogSheetCancelKeepsThePick() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectLocalISO(path: "/tmp/ubuntu.iso", bookmark: nil)
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        vc.linuxImageCatalogSheetDidCancel(makeCatalogSheet())

        #expect(vm.linuxSelection == .localISO(path: "/tmp/ubuntu.iso", bookmark: nil))
        #expect(findButton(titled: "ISO File…", in: vc.view)?.state == .on)
    }

    @Test("Choosing from the URL sheet commits the image and lights its radio")
    func urlSheetChoiceCommits() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        let image = makeResolvedLinuxImage(
            isoURLString: "https://mirror.example/alpine-3.22-aarch64.iso",
            filename: "alpine-3.22-aarch64.iso")
        vc.linuxImageURLSheet(makeURLSheet(), didChoose: image)

        #expect(vm.linuxSelection == .customURL(image))
        #expect(findButton(titled: "Image URL…", in: vc.view)?.state == .on)
    }

    @Test("Cancelling the URL sheet leaves the earlier pick standing")
    func urlSheetCancelKeepsThePick() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectLinuxCatalogEntry(makeLinuxCatalogEntry())
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        vc.linuxImageURLSheetDidCancel(makeURLSheet())

        #expect(findButton(titled: "Choose a Distribution…", in: vc.view)?.state == .on)
        #expect(findButton(titled: "Image URL…", in: vc.view)?.state == .off)
    }

    /// A picker instance to hand the delegate methods, which ignore it.
    private func makeCatalogSheet() -> LinuxImageCatalogSheetContentViewController {
        LinuxImageCatalogSheetContentViewController(entries: [makeLinuxCatalogEntry()])
    }

    /// A URL sheet instance to hand the delegate methods, which ignore it.
    private func makeURLSheet() -> LinuxImageURLSheetContentViewController {
        LinuxImageURLSheetContentViewController(resolveService: MockLinuxImageResolveService())
    }

    @Test("Switching to Linux Kernel updates the model and shows kernel rows")
    func switchToKernel() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        guard let segmented = firstSubview(NSSegmentedControl.self, in: vc.view) else {
            Issue.record("Expected an NSSegmentedControl")
            return
        }
        segmented.selectedSegment = 1
        segmented.sendAction(segmented.action, to: segmented.target)

        #expect(vm.selectedBootMode == .linuxKernel)
        #expect(findLabel(withText: "Kernel", in: vc.view) != nil)
        #expect(findLabel(withText: "Initrd", in: vc.view) != nil)
    }

    @Test("Kernel command line writes back to the model on edit")
    func commandLineWriteBack() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        guard let field = findEditableField(in: vc.view) else {
            Issue.record("Expected an editable command-line NSTextField")
            return
        }
        // The default is both displayed and committed, so the value the user
        // sees is the one `buildConfiguration()` will use.
        #expect(field.stringValue == "console=hvc0")
        #expect(vm.kernelCommandLine == "console=hvc0")

        field.stringValue = "root=/dev/vda console=hvc0"
        vc.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(vm.kernelCommandLine == "root=/dev/vda console=hvc0")
    }

    @Test("Default kernel command line is committed to the model, not just displayed")
    func defaultCommandLineCommitted() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        #expect(vm.kernelCommandLine == nil)

        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        // Building the kernel section seeds the default so an untouched field
        // doesn't leave the guest booting without the shown command line.
        #expect(vm.kernelCommandLine == "console=hvc0")
    }

    @Test("An explicitly cleared command line is not re-seeded with the default")
    func clearedCommandLineNotReseeded() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        vm.kernelCommandLine = ""  // user cleared it intentionally
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(vm.kernelCommandLine == "")
    }
}
