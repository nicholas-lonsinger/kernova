#if os(macOS)
import Foundation
import KernovaAgentInstall
import Security

/// Whether launchd would launch an update in place of the running agent.
///
/// launchd attaches a spawn constraint built from the agent's designated requirement to the agent's Background
/// Task Management job, and kills a launch whose code fails it ("Launch Constraint Violation", `CODESIGNING`
/// code 4) — Apple, "Defining launch environment and library constraints". The running agent was launched
/// under that constraint, so a build that meets the running agent's own designated requirement is one launchd
/// will launch from the install; only a fresh install registers the job under another.
enum LaunchRequirement {
    /// Why launchd would not launch the bundle at `path` in place of the running agent:
    /// `UPDATE_LAUNCH_REFUSED`, rejecting the payload, when its signature fails the running agent's designated
    /// requirement; on the install's own account when that requirement cannot be read.
    static func refusal(ofBundleAt path: String) -> PayloadRefusal? {
        switch runningRequirement() {
        case .success(let requirement):
            return refusal(ofBundleAt: path, against: requirement)
        case .failure(let failure):
            return PayloadRefusal(
                .updateInstallFailed, "the running agent's designated requirement: \(failure)", rejectsPayload: false)
        }
    }

    /// Why the bundle at `path` fails `requirement`, as `UPDATE_LAUNCH_REFUSED`; nil when its signature meets it.
    ///
    /// Checks the architecture a launch runs and leaves the bundle's resources to the self-test, as a launch
    /// does: an ad-hoc agent's own requirement names only its running slice's cdhash.
    static func refusal(ofBundleAt path: String, against requirement: SecRequirement) -> PayloadRefusal? {
        let code: SecStaticCode
        switch staticCode(at: path) {
        case .success(let staticCode): code = staticCode
        case .failure(let failure): return PayloadRefusal(.updateLaunchRefused, "the update's signature: \(failure)")
        }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status != errSecSuccess else { return nil }
        let failure = Failure(operation: "SecStaticCodeCheckValidity", status: status)
        return PayloadRefusal(
            .updateLaunchRefused, "the update fails the running agent's designated requirement: \(failure)")
    }

    /// The running agent's designated requirement.
    static func runningRequirement() -> Result<SecRequirement, Failure> {
        var running: SecCode?
        var status = SecCodeCopySelf(SecCSFlags(), &running)
        guard status == errSecSuccess, let running else {
            return .failure(Failure(operation: "SecCodeCopySelf", status: status))
        }
        var code: SecStaticCode?
        status = SecCodeCopyStaticCode(running, SecCSFlags(), &code)
        guard status == errSecSuccess, let code else {
            return .failure(Failure(operation: "SecCodeCopyStaticCode", status: status))
        }
        return designatedRequirement(of: code)
    }

    /// The designated requirement of the code at `path`.
    static func designatedRequirement(ofCodeAt path: String) -> Result<SecRequirement, Failure> {
        staticCode(at: path).flatMap(designatedRequirement(of:))
    }

    private static func designatedRequirement(of code: SecStaticCode) -> Result<SecRequirement, Failure> {
        var requirement: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement)
        guard status == errSecSuccess, let requirement else {
            return .failure(Failure(operation: "SecCodeCopyDesignatedRequirement", status: status))
        }
        return .success(requirement)
    }

    private static func staticCode(at path: String) -> Result<SecStaticCode, Failure> {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &code)
        guard status == errSecSuccess, let code else {
            return .failure(Failure(operation: "SecStaticCodeCreateWithPath", status: status))
        }
        return .success(code)
    }

    /// A Security framework call that failed, and its status.
    struct Failure: Error, CustomStringConvertible {
        var operation: String
        var status: OSStatus

        var description: String {
            let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "unknown"
            return "\(operation): \(status) (\(message))"
        }
    }
}
#endif
