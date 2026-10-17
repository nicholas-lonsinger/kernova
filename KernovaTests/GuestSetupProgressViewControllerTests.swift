import AppKit
import Foundation
import Testing

@testable import Kernova
@testable import KernovaCore

@Suite("GuestSetupProgressViewController Tests", .caseScoped)
@MainActor
struct GuestSetupProgressViewControllerTests {
    /// A progress view for `instance`'s pending setup, loaded and showing its
    /// current step.
    private func makeProgressView(for instance: VMInstance) -> GuestSetupProgressViewController {
        let vc = GuestSetupProgressViewController(
            instance: instance, descriptor: .forSetup(of: instance), onCancel: {})
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        return vc
    }

    /// Moves `instance` to its setup's next step and redraws `vc` for it.
    private func advance(_ instance: VMInstance, in vc: GuestSetupProgressViewController) {
        instance.setupState?.advance(progress: .fraction(0))
        vc.viewDidAppear()
    }

    @Test("The caption shows only while Verify runs, naming what the image is checked against")
    func captionShowsOnlyDuringVerify() {
        let entry = makeLinuxCatalogEntry(manifestDirectoryURLString: "https://checksums.example/")
        let instance = VMInstanceFixture.make(name: "Debian") {
            $0.linuxInstallContext = LinuxInstallContext(source: .catalogEntry(entry))
        }
        instance.setupState = .linuxImage(
            digestSource: instance.configuration.linuxInstallContext?.source.digestSource)
        let vc = makeProgressView(for: instance)

        #expect(instance.setupState?.currentStep?.id == .download)
        #expect(findLabel(containing: "Checking against", in: vc.view) == nil)

        advance(instance, in: vc)

        #expect(instance.setupState?.currentStep?.id == .verify)
        let caption = findLabel(
            withText: "Checking against the checksum list on checksums.example", in: vc.view)
        #expect(caption != nil)
        #expect(caption?.isHidden == false)
    }
}
