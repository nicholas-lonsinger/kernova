import Foundation

/// Get/set pair that bridges an `@Observable` view model into AppKit controls.
///
/// The read closure is invoked inside an ``ObservationLoop``'s `track`
/// block to register the value as a tracked dependency; the write closure
/// routes through whatever dispatcher the view model exposes (e.g.
/// ``VMLibraryViewModel/updateConfiguration(of:mutate:)``) so live-policy /
/// reconciliation side effects still fire.
///
/// Two-way binding semantics:
/// 1. The owning AppKit control reads `get()` inside its observation `track`
///    so external mutations (peer view, persisted load, guest-driven config
///    update) re-fire the loop and the control updates itself in `apply`.
/// 2. The control's `target/action` (or text-field delegate) calls `set(_:)`,
///    which the view model persists and reconciles. The observation loop
///    fires once more, but because the value didn't change in net, the
///    re-apply is a no-op.
@MainActor
struct Observed<Value> {
    let get: () -> Value
    let set: (Value) -> Void

    init(
        get: @escaping () -> Value,
        set: @escaping (Value) -> Void
    ) {
        self.get = get
        self.set = set
    }

    /// Convenience for a read-only `Observed` — typical for AppKit views
    /// that mirror state but don't write it back.
    static func readOnly(_ read: @escaping () -> Value) -> Observed<Value> {
        Observed(get: read, set: { _ in })
    }
}

extension Observed where Value: Equatable {
    /// Returns `true` when the new value differs from the current one.
    ///
    /// Useful inside ``BindableTextField``-style write paths to skip the
    /// view-model round trip on no-op writes (typing the same string back).
    func wouldChange(_ candidate: Value) -> Bool {
        get() != candidate
    }
}
