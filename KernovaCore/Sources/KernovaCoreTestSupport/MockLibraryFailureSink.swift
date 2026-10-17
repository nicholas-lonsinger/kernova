import Foundation

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore

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
    /// Parallel to `errors`: what each failure was about.
    private(set) var errorSubjects: [AlertSubject] = []

    /// How many times the library asked for the config check to come up.
    private(set) var checkRequests = 0

    /// Wire this to `VMLibrary.onUnreadableFilesFound`.
    func recordCheckRequest() {
        checkRequests += 1
    }

    /// Fired after each recorded failure.
    let recorded = AsyncGate()

    /// Wire this to `VMLibrary.onFailure`.
    func record(title: String, message: String, subject: AlertSubject) {
        errors.append(message)
        errorTitles.append(title)
        errorSubjects.append(subject)
        recorded.notify()
    }

    // MARK: - Mirror accessors

    var showError: Bool { !errors.isEmpty }
    var errorMessage: String? { errors.last }
    var errorTitle: String? { errorTitles.last }
    var errorSubject: AlertSubject? { errorSubjects.last }

    func reset() {
        errors.removeAll()
        errorTitles.removeAll()
        errorSubjects.removeAll()
        checkRequests = 0
    }
}
