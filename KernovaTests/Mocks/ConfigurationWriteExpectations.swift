import Foundation
@testable import Kernova

/// What a test asserts about how a configuration write ended.
extension VMLibrary.ConfigurationWrite {
    var landed: Bool {
        if case .saved = self { true } else { false }
    }

    var refusedForMACAddress: Bool {
        if case .refused(.macAddressInUse) = self { true } else { false }
    }

    var refusedForSession: Bool {
        if case .refused(.sessionNotAttachable) = self { true } else { false }
    }

    var refusedWhilePreparing: Bool {
        if case .refused(.preparing) = self { true } else { false }
    }

    var refusedOutsideALibrary: Bool {
        if case .refused(.notInLibrary) = self { true } else { false }
    }

    var failedToSave: Bool {
        if case .notSaved = self { true } else { false }
    }
}
