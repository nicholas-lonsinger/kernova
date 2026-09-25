import Foundation

/// Where a VM bundle's state files are read and replaced, one coordinated
/// access at a time.
///
/// Each call wraps its whole body in one coordination on the bundle directory,
/// so every file the body touches is read or replaced under it. A body must
/// not start a second access on the same bundle: a nested coordination of the
/// same package from the same thread waits on the outer one forever.
protocol VMBundleFileAccessing: Sendable {
    /// Runs `body` under a coordinated read of the bundle at `bundleURL`.
    func reading<T>(_ bundleURL: URL, _ body: (any VMBundleFileReading) throws -> T) throws -> T

    /// Runs `body` under a coordinated write of the bundle at `bundleURL`.
    func writing<T>(_ bundleURL: URL, _ body: (any VMBundleFileWriting) throws -> T) throws -> T
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
