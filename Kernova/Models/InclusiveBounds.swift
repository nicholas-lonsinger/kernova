/// The values from `lower` through `upper`, checked as two comparisons.
///
/// Unlike a `ClosedRange`, it can hold bounds read at runtime in either order:
/// with `lower` above `upper` it contains nothing, where forming the range
/// would trap.
package struct InclusiveBounds<Bound: Comparable & Sendable>: Sendable, Equatable {
    package let lower: Bound
    package let upper: Bound

    package init(lower: Bound, upper: Bound) {
        self.lower = lower
        self.upper = upper
    }

    func contains(_ value: Bound) -> Bool {
        value >= lower && value <= upper
    }

    /// `value`, or the bound it passes.
    package func clamp(_ value: Bound) -> Bound {
        if value < lower { return lower }
        if value > upper { return upper }
        return value
    }
}
