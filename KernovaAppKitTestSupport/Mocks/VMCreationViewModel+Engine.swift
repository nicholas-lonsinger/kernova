import Foundation

@testable import KernovaCore
@testable import KernovaUI
@testable import KernovaVirtualization

// KernovaTests compiles the test-support folders into its own module;
// KernovaUITests links them as products.
#if !TEST_SUPPORT_COMPILED_IN
import KernovaTestSupport
@testable import KernovaCoreTestSupport
#endif

extension VMCreationViewModel {
    /// A wizard over the real Virtualization engine, as the app builds one,
    /// with whichever collaborators the test scripts.
    static func overEngine(
        probeService: any RestoreImageProbing = RestoreImageProbeService(),
        localImageInspector: any LocalRestoreImageInspecting = LocalRestoreImageInspector(),
        ipswService: any IPSWProviding = IPSWService(),
        linuxImageResolveService: any LinuxImageResolving = LinuxImageResolveService()
    ) -> VMCreationViewModel {
        VMCreationViewModel(
            probeService: probeService, host: VirtualizationHost(),
            localImageInspector: localImageInspector, ipswService: ipswService,
            linuxImageResolveService: linuxImageResolveService)
    }
}
