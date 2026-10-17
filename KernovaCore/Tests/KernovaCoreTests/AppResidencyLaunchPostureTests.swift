import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Unit tests for `AppResidencyPolicy.launchPosture` — what a launch puts
/// on screen, given what it asked for and the residency preference.
@Suite("AppResidencyPolicy launch posture", .caseScoped)
struct AppResidencyLaunchPostureTests {
    private func posture(
        origin: AppResidencyPolicy.LaunchProvenance.Origin = .user,
        isHidden: Bool = false,
        keepInMenuBar: Bool
    ) -> AppResidencyPolicy.LaunchPosture {
        AppResidencyPolicy.launchPosture(
            for: AppResidencyPolicy.LaunchProvenance(origin: origin, isHidden: isHidden),
            keepInMenuBar: keepInMenuBar)
    }

    /// The whole matrix in one assertion, so a changed rule cannot quietly take
    /// a window away from a launch that needs one — the failure a headless
    /// start risks.
    @Test("Only a login launch and a hidden one stay headless, and only with the status item on")
    func headlessSetIsExhaustive() {
        var headless: [String] = []
        for origin in [
            AppResidencyPolicy.LaunchProvenance.Origin.user, .loginItem,
        ] {
            for isHidden in [true, false] {
                for keepInMenuBar in [true, false]
                where posture(origin: origin, isHidden: isHidden, keepInMenuBar: keepInMenuBar)
                    == .headless
                {
                    headless.append(
                        "\(origin.rawValue) hidden=\(isHidden) keepInMenuBar=\(keepInMenuBar)")
                }
            }
        }

        #expect(
            headless == [
                "user hidden=true keepInMenuBar=true",
                "loginItem hidden=true keepInMenuBar=true",
                "loginItem hidden=false keepInMenuBar=true",
            ])
    }
}
