/// Suspends for the rest of the process's life, arming no clock: a double for
/// an await that never lands, which the code under test stays parked on.
public func parkForever() async {
    await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
}
