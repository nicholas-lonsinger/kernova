import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The host-state model and its coding: what a round trip preserves, and what
/// a key the JSON does not carry decodes to.
@Suite("VMHostState Tests", .caseScoped)
struct VMHostStateTests {
    @Test("A key the JSON does not carry decodes to its default")
    func absentKeysTakeTheirDefaults() throws {
        let data = Data(#"{"displayPreference":"fullscreen"}"#.utf8)

        #expect(
            try VMConfiguration.makeJSONDecoder().decode(VMHostState.self, from: data)
                == VMHostState(displayPreference: .fullscreen))
    }
}
