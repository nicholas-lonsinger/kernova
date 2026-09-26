import Foundation
@testable import Kernova

/// What a test asserts about how a settings write ended.
extension VMLibrary.SettingsWrite {
    var landed: Bool {
        if case .saved = self { true } else { false }
    }

    var refusedForMACAddress: Bool {
        if case .refused(.macAddressInUse) = self { true } else { false }
    }

    var refusedForNoLibrary: Bool {
        if case .refused(.noLibrary) = self { true } else { false }
    }

    /// The fields a write moved that its permit may not write, when that is
    /// what refused it.
    var fieldsOutsidePermit: [String]? {
        if case .refused(.outsidePermit(let refusal)) = self { refusal.fields } else { nil }
    }

    var failedToSave: Bool {
        if case .notSaved = self { true } else { false }
    }
}
