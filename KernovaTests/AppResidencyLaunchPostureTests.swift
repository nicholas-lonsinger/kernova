import Testing

@testable import Kernova

/// Unit tests for `AppResidencyController.launchPosture` — what a launch puts
/// on screen, given what it asked for and the residency preference.
@Suite("AppResidencyController launch posture", .admissionGated)
struct AppResidencyLaunchPostureTests {
    private func posture(
        origin: AppResidencyController.LaunchProvenance.Origin = .user,
        isHidden: Bool = false,
        keepInMenuBar: Bool
    ) -> AppResidencyController.LaunchPosture {
        AppResidencyController.launchPosture(
            for: AppResidencyController.LaunchProvenance(origin: origin, isHidden: isHidden),
            keepInMenuBar: keepInMenuBar)
    }

    @Test("A launch that asked for no window comes up headless with the status item on")
    func hiddenLaunchWithStatusItemIsHeadless() {
        #expect(posture(isHidden: true, keepInMenuBar: true) == .headless)
    }

    /// Nothing would reach a headless process with the status item off, so the
    /// library is created behind the hide and the Dock icon reaches it.
    @Test("A hidden launch with no status item presents instead")
    func hiddenLaunchWithoutStatusItemPresents() {
        #expect(posture(isHidden: true, keepInMenuBar: false) == .present)
    }

    @Test("A login launch answers the same pair a hidden one does")
    func loginLaunchMatchesTheHiddenRule() {
        #expect(posture(origin: .loginItem, keepInMenuBar: true) == .headless)
        #expect(posture(origin: .loginItem, keepInMenuBar: false) == .present)
        // Hidden or not makes no difference to a login launch: it already asked
        // to have Kernova running rather than to be shown it.
        #expect(posture(origin: .loginItem, isHidden: true, keepInMenuBar: true) == .headless)
        #expect(posture(origin: .loginItem, isHidden: true, keepInMenuBar: false) == .present)
    }

    @Test("A plain launch presents, whatever the residency preference")
    func plainLaunchPresents() {
        #expect(posture(keepInMenuBar: true) == .present)
        #expect(posture(keepInMenuBar: false) == .present)
    }

    /// The whole matrix in one assertion, so a changed rule cannot quietly take
    /// a window away from a launch that needs one — the failure a headless
    /// start risks.
    @Test("Only a login launch and a hidden one stay headless, and only with the status item on")
    func headlessSetIsExhaustive() {
        var headless: [String] = []
        for origin in [
            AppResidencyController.LaunchProvenance.Origin.user, .loginItem,
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
