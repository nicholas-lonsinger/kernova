import Foundation

/// Everything Kernova persists as one VM's settings: the ``VMConfiguration`` a
/// snapshot captures and the ``VMHostState`` it does not.
///
/// What the `get`/`set` keyspace addresses.
struct VMSettings: Sendable, Equatable {
    var configuration: VMConfiguration
    var hostState: VMHostState
}
