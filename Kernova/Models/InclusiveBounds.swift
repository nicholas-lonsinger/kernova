/// The values from `lower` through `upper`, checked as two comparisons.
///
/// Unlike a `ClosedRange`, it can hold bounds read at runtime in either order:
/// with `lower` above `upper` it contains nothing, where forming the range
/// would trap.
struct InclusiveBounds<Bound: Comparable & Sendable>: Sendable, Equatable {
    let lower: Bound
    let upper: Bound

    func contains(_ value: Bound) -> Bool {
        value >= lower && value <= upper
    }

    /// `value`, or the bound it passes.
    func clamp(_ value: Bound) -> Bound {
        if value < lower { return lower }
        if value > upper { return upper }
        return value
    }
}
