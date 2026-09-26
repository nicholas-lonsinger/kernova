import Foundation

/// What holds a bundle's run lock for as long as it is retained, released the
/// moment the last reference goes.
typealias VMBundleLockHolder = AnyObject & Sendable

/// Where a VM bundle's state files are read and replaced, one coordinated
/// access at a time, and where its directory's run lock is taken.
///
/// Each call wraps its whole body in one coordination on the bundle directory,
/// so every file the body touches is read or replaced under it. A body must
/// not start a second access on the same bundle: a nested coordination of the
/// same package from the same thread waits on the outer one forever.
protocol VMBundleFileAccessing: Sendable {
    /// Takes the run lock on the bundle directory at `bundleURL` without
    /// waiting.
    ///
    /// The lock rides the directory's inode, so it holds across a rename, a
    /// Finder move and a move to the Trash; the kernel releases it when the
    /// process exits.
    ///
    /// - Returns: what holds the lock, or `nil` when another holder has it —
    ///   another copy of Kernova, or this process's own earlier acquire.
    /// - Throws: why the directory could not be opened.
    func lockBundle(at bundleURL: URL) throws -> (any VMBundleLockHolder)?

    /// Whether any holder has the run lock on the bundle directory at
    /// `bundleURL`, this process's own included — so asked only while this
    /// copy holds none, when a holder can only be another copy.
    ///
    /// - Throws: why the directory could not be opened.
    func isBundleLockedElsewhere(at bundleURL: URL) throws -> Bool

    /// Runs `body` under a coordinated read of the bundle at `bundleURL`.
    func reading<T>(_ bundleURL: URL, _ body: (any VMBundleFileReading) throws -> T) throws -> T

    /// Runs `body` under a coordinated write of the bundle at `bundleURL`.
    func writing<T>(
        _ bundleURL: URL, _ key: borrowing VMBundleFileWriteKey,
        _ body: (any VMBundleFileWriting) throws -> T
    ) throws -> T
}

/// The files of one bundle as a coordinated access sees them.
protocol VMBundleFileReading {
    /// The bytes at `relativePath` inside the bundle, or `nil` when no file is
    /// there; throws when one is there and cannot be read.
    func data(atRelativePath relativePath: String) throws -> Data?
}

/// ``VMBundleFileReading`` plus the one write a state file takes.
protocol VMBundleFileWriting: VMBundleFileReading {
    /// Replaces the file at `relativePath` with `data` in one atomic step,
    /// creating the directory it sits in when that is missing inside the
    /// bundle; a bundle that is not there fails the write.
    func replace(atRelativePath relativePath: String, with data: Data) throws
}
