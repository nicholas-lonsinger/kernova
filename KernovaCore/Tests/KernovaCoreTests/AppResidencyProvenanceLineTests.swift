import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Unit tests for `AppResidencyPolicy.residentProvenanceLine`.
///
/// The pure formatter behind the resident app's startup `.notice` log line
/// (#455). Launch Services elects among every on-disk copy by `CFBundleVersion`,
/// so the copy that actually launched need not be the one the developer
/// expected; this one greppable line makes "which copy is this" legible from the
/// log alone.
@Suite("AppResidencyPolicy.residentProvenanceLine", .caseScoped)
struct AppResidencyProvenanceLineTests {
    private func provenance(
        _ origin: AppResidencyPolicy.LaunchProvenance.Origin, isHidden: Bool
    ) -> AppResidencyPolicy.LaunchProvenance {
        AppResidencyPolicy.LaunchProvenance(origin: origin, isHidden: isHidden)
    }

    @Test("formats bundle path, build, configuration, and entitlement state into one line")
    func formatsAllFields() {
        #expect(
            AppResidencyPolicy.residentProvenanceLine(
                bundlePath: "/Applications/Kernova.app",
                build: "142",
                configuration: "Release",
                vmNetworkingEntitled: true,
                launch: provenance(.user, isHidden: false))
                == "bundle=/Applications/Kernova.app build=142 config=Release "
                + "vmNetworking=entitled launch=user hidden=false")
    }

    @Test("reports an unentitled signature")
    func unentitledSignature() {
        #expect(
            AppResidencyPolicy.residentProvenanceLine(
                bundlePath: "/Applications/Kernova.app",
                build: "142",
                configuration: "Debug",
                vmNetworkingEntitled: false,
                launch: provenance(.loginItem, isHidden: false))
                == "bundle=/Applications/Kernova.app build=142 config=Debug "
                + "vmNetworking=unentitled launch=loginItem hidden=false")
    }

    /// The pair that decides the posture, so a launch that came up with no
    /// window is legible from the log alone.
    @Test("reports a launch that asked for no window")
    func hiddenLaunch() {
        #expect(
            AppResidencyPolicy.residentProvenanceLine(
                bundlePath: "/Applications/Kernova.app",
                build: "142",
                configuration: "Debug",
                vmNetworkingEntitled: false,
                launch: provenance(.user, isHidden: true))
                == "bundle=/Applications/Kernova.app build=142 config=Debug "
                + "vmNetworking=unentitled launch=user hidden=true")
    }
}
