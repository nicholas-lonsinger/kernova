import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// How a create, clone or import failure is worded: the file it failed on is
/// named by the bundle the user knows, never by the staged path under the
/// hidden staging directory.
@Suite("VMArrival failure wording", .caseScoped)
struct VMArrivalFailureTests {
    private let stagingRoot = URL(fileURLWithPath: "/Lib/VMs/.Staging/1234", isDirectory: true)
    private var staged: URL {
        stagingRoot.appendingPathComponent("8E8EE351-CA0A-49C5-A0FC-005740C94921.kernova")
    }
    private let source = VMArrival.Source.importing(
        URL(fileURLWithPath: "/Users/me/Desktop/Mac.kernova", isDirectory: true))

    private func message(_ error: any Error, kind: VMArrival.Kind = .importing, source: VMArrival.Source?)
        -> String
    {
        VMArrival.failureMessage(
            for: error, kind: kind, name: "Mac", stagedURL: staged, source: source)
    }

    @Test(
        "A failure naming only the staging directory states its reason and no path",
        arguments: [
            "/Lib/VMs/.Staging/1234", "/Lib/VMs/.Staging", "/Lib/VMs/.Staging/.1234",
        ])
    func stagingOnlyFailureNamesNoPath(path: String) {
        let error = NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
            userInfo: [
                NSFilePathErrorKey: path,
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue)),
            ])

        #expect(message(error, source: source) == "Permission denied.")
    }
}
