import Foundation
import KernovaTestSupport
import Testing
import UniformTypeIdentifiers

@testable import KernovaCore

/// `UTType(exportedAs:)` reads the declaration from the main bundle, so the
/// test host declares the app's exported types (`Tools/check-test-host-declarations.sh`).
@Suite("Kernova's exported types in the test host", .caseScoped)
struct KernovaUTTypeTests {
    @Test("The VM bundle type is the app's declaration: a package with the kernova extension")
    func vmBundleTypeIsDeclared() {
        let type = UTType.kernovaVM
        #expect(type.isDeclared)
        #expect(type.conforms(to: .package))
        #expect(type.preferredFilenameExtension == "kernova")
    }
}
