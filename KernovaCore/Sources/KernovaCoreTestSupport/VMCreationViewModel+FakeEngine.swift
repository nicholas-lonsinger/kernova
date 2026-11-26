import Foundation

@testable import KernovaCore

extension VMCreationViewModel {
    /// A wizard over ``FakeVirtualizationHost`` and scripted engine services,
    /// with whichever collaborators the test scripts, beside a library whose
    /// VMs go by `takenNames`.
    package static func overFakeEngine(
        probeService: any RestoreImageProbing = RestoreImageProbeService(),
        localImageInspector: any LocalRestoreImageInspecting = MockLocalRestoreImageInspector(),
        ipswService: any IPSWProviding = MockIPSWService(),
        linuxImageResolveService: any LinuxImageResolving = LinuxImageResolveService(),
        host: any VirtualizationHostProviding = FakeVirtualizationHost(),
        downloadsDirectory: URL = makeTestDownloadsDirectory(),
        takenNames: @escaping @MainActor () -> [String] = { [] }
    ) -> VMCreationViewModel {
        VMCreationViewModel(
            probeService: probeService, host: host,
            localImageInspector: localImageInspector, ipswService: ipswService,
            linuxImageResolveService: linuxImageResolveService,
            downloadsDirectory: downloadsDirectory, takenNames: takenNames)
    }
}
