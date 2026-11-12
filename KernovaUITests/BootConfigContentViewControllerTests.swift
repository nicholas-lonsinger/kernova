import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

@Suite("BootConfigContentViewController Tests", .caseScoped)
@MainActor
struct BootConfigContentViewControllerTests {
    /// The descriptions name what each source does; the popover keeps only
    /// when a download happens, which they don't say.
    @Test("The title popover says when a downloaded image is fetched")
    func titlePopoverSaysWhenImagesDownload() throws {
        let vm = VMCreationViewModel.overEngine()
        vm.selectedOS = .linux
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        let info = try #require(
            firstSubview(InfoButtonView.self, in: vc.view) {
                $0.button.toolTip == "About Boot Configuration"
            })
        #expect(
            info.paragraphs == [
                .body(
                    "Choose a Distribution… and Image URL… download their image when you first "
                        + "start the virtual machine.")
            ])
    }

    @Test("EFI mode offers all three image sources, with none picked to start")
    func efiShowsEveryImageSource() {
        let vm = VMCreationViewModel.overEngine()
        vm.selectedOS = .linux
        vm.linuxBootMode = .efi
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(firstSubview(NSSegmentedControl.self, in: vc.view)?.selectedSegment == 0)
        #expect(findButton(titled: "Choose a Distribution…", in: vc.view)?.state == .off)
        #expect(findButton(titled: "Image URL…", in: vc.view)?.state == .off)
        #expect(findButton(titled: "ISO File…", in: vc.view)?.state == .off)
        #expect(findLabel(withText: "Kernel", in: vc.view) == nil)
    }

    @Test("A catalog pick lights its radio and names the image on a badge")
    func catalogPickRendersBadge() {
        let vm = VMCreationViewModel.overEngine()
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
        // Named by the checksum list's host, the trust anchor.
        #expect(
            findLabel(
                withText: "Checked after download against the checksum list on cdimage.debian.org",
                in: vc.view) != nil)
        #expect(findButton(titled: "Change…", in: vc.view) != nil)
    }

    @Test("A local ISO lights its radio and shows the file path")
    func localISORendersPathBadge() {
        let vm = VMCreationViewModel.overEngine()
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
        let vm = VMCreationViewModel.overEngine()
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
        let vm = VMCreationViewModel.overEngine()
        vm.selectedOS = .linux
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        let entry = makeLinuxCatalogEntry(distribution: "Debian", version: "13")
        vc.commitCatalogEntry(entry)

        #expect(vm.linuxSelection == .catalogEntry(entry))
        #expect(findButton(titled: "Choose a Distribution…", in: vc.view)?.state == .on)
    }

    @Test("Choosing from the URL sheet commits the image and lights its radio")
    func urlSheetChoiceCommits() {
        let vm = VMCreationViewModel.overEngine()
        vm.selectedOS = .linux
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        let image = makeCustomLinuxImage()
        vc.commitCustomImage(image, sizeBytes: 1_073_741_824)

        #expect(vm.linuxSelection == .customURL(image: image, sizeBytes: 1_073_741_824))
        #expect(findButton(titled: "Image URL…", in: vc.view)?.state == .on)
    }

    @Test("Switching to Linux Kernel updates the model and shows kernel rows")
    func switchToKernel() {
        let vm = VMCreationViewModel.overEngine()
        vm.selectedOS = .linux
        vm.linuxBootMode = .efi
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        guard let segmented = firstSubview(NSSegmentedControl.self, in: vc.view) else {
            Issue.record("Expected an NSSegmentedControl")
            return
        }
        segmented.selectedSegment = 1
        segmented.sendAction(segmented.action, to: segmented.target)

        #expect(vm.linuxBootMode == .linuxKernel)
        #expect(findLabel(withText: "Kernel", in: vc.view) != nil)
        #expect(findLabel(withText: "Initrd", in: vc.view) != nil)
    }

    @Test("Kernel command line writes back to the model on edit")
    func commandLineWriteBack() {
        let vm = VMCreationViewModel.overEngine()
        vm.selectedOS = .linux
        vm.linuxBootMode = .linuxKernel
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
}
