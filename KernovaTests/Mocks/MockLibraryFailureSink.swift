import Foundation

/// Records what `VMLibrary` hands to its `onFailure` hook, so tests can assert
/// which alert the library asked for with no presenter in the picture.
///
/// The mirror accessors match `MockVMLibraryPresenting`'s error side, so one
/// assertion reads the same either side of the adapter.
@MainActor
final class MockLibraryFailureSink {
    private(set) var errors: [String] = []
    /// Parallel to `errors`: the alert title each message was raised under.
    private(set) var errorTitles: [String] = []

    /// Wire this to `VMLibrary.onFailure`.
    func record(title: String, message: String) {
        errors.append(message)
        errorTitles.append(title)
    }

    // MARK: - Mirror accessors

    var showError: Bool { !errors.isEmpty }
    var errorMessage: String? { errors.last }
    var errorTitle: String? { errorTitles.last }

    func reset() {
        errors.removeAll()
        errorTitles.removeAll()
    }
}
