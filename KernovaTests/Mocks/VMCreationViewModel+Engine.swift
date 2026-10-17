import Foundation

@testable import Kernova
@testable import KernovaCore
@testable import KernovaVirtualization

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
