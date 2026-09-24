import Foundation

/// Everything Kernova persists as one VM's settings: the ``VMConfiguration`` a
/// snapshot captures and the ``VMHostState`` it does not.
///
/// What the `get`/`set` keyspace addresses, and what one write through
/// `VMLibrary.updateSettings(of:ifNotSaved:mutate:)` changes either half of.
struct VMSettings: Sendable, Equatable {
    var configuration: VMConfiguration
    var hostState: VMHostState
}
