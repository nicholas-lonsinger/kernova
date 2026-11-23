import Foundation

@testable import KernovaCore

/// What a test asserts about how a settings write ended.
extension VMLibrary.SettingsWrite {
    var landed: Bool {
        if case .saved = self { true } else { false }
    }

    var failedToSave: Bool {
        if case .notSaved = self { true } else { false }
    }
}
