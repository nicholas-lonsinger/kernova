import Foundation

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaVirtualization

extension VMCreationViewModel {
    /// A wizard over the real Virtualization engine, as the app builds one,
    /// with whichever collaborators the test scripts.
    static func overEngine(
        probeService: any RestoreImageProbing = RestoreImageProbeService(),
        localImageInspector: any LocalRestoreImageInspecting = LocalRestoreImageInspector(),
        ipswService: any IPSWProviding = IPSWService(),
        linuxImageResolveService: any LinuxImageResolving = LinuxImageResolveService(),
        downloadsDirectory: URL = makeTestDownloadsDirectory()
    ) -> VMCreationViewModel {
        VMCreationViewModel(
            probeService: probeService, host: VirtualizationHost(),
            localImageInspector: localImageInspector, ipswService: ipswService,
            linuxImageResolveService: linuxImageResolveService,
            downloadsDirectory: downloadsDirectory)
    }
}
