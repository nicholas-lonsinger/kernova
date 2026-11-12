import Foundation
import KernovaAgentCore
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The app-wide paste ceiling reaching a running guest's agent connections.
///
/// The ceiling lives in `AppPreferences`, so it produces no `VMConfiguration`
/// diff for `applyLivePolicy` to carry — without an explicit re-push a running
/// guest keeps enforcing the value it was handed at connect, and the two ends
/// silently disagree until the next reconnect.
@Suite("Clipboard paste ceiling policy push", .serialized, .caseScoped)
@MainActor
struct ClipboardPasteLimitPolicyPushTests {
}
