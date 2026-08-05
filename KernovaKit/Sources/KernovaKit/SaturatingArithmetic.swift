extension FixedWidthInteger {
    /// `self + other`, clamped to the bound it would pass rather than wrapping
    /// or trapping.
    ///
    /// For sums of peer-declared sizes, whose only real bound is the width of
    /// the field carrying them: a wrapping `&+` turns an absurd total into a
    /// small one that then *passes* the cap it should fail, and a trapping `+`
    /// turns the same input into a process kill. Saturating keeps the
    /// comparison honest — an absurd total stays absurd.
    public func saturatingAdding(_ other: Self) -> Self {
        let (sum, overflow) = addingReportingOverflow(other)
        guard overflow else { return sum }
        return other < 0 ? .min : .max
    }
}
