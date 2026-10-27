import Foundation

@testable import KernovaCore

extension VMCreationViewModel {
    /// A wizard over ``FakeVirtualizationHost`` and scripted engine services,
    /// with whichever collaborators the test scripts.
    package static func overFakeEngine(
        probeService: any RestoreImageProbing = RestoreImageProbeService(),
        localImageInspector: any LocalRestoreImageInspecting = MockLocalRestoreImageInspector(),
        ipswService: any IPSWProviding = MockIPSWService(),
        linuxImageResolveService: any LinuxImageResolving = LinuxImageResolveService(),
        host: any VirtualizationHostProviding = FakeVirtualizationHost(),
        downloadsDirectory: URL = makeTestDownloadsDirectory()
    ) -> VMCreationViewModel {
        VMCreationViewModel(
            probeService: probeService, host: host,
            localImageInspector: localImageInspector, ipswService: ipswService,
            linuxImageResolveService: linuxImageResolveService,
            downloadsDirectory: downloadsDirectory)
    }
}
