#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import KernovaFileTree

/// How a reporting surface of the install layer names a failed file-system call.
public protocol InstallFileFailure: Error {
    /// `operation` on the full path `path` failing with `errno`.
    init(operation: String, path: String, errno: Int32)
}

/// A directory of an install, open, through which the install layer reaches every name in it: each name is
/// resolved relative to the directory's descriptor through its tree file system, so a link is never followed
/// and every open takes the kernel's containment where the OS has it. Everything made in it is handed to its
/// owner; every failure is reported as a `Failure` naming the full path.
public struct InstallDirectory<Failure: InstallFileFailure>: ~Copyable, Sendable {
    /// The directory, open until this ends.
    let descriptor: Int32
    /// Its path, for messages.
    public let path: String
    /// Who everything made in it belongs to; nil for this process.
    let owner: Installer.Owner?
    let fileSystem: any MutableTreeFileSystem

    /// Takes ownership of `descriptor`, the directory at `path`.
    init(descriptor: Int32, path: String, owner: Installer.Owner?, fileSystem: any MutableTreeFileSystem) {
        self.descriptor = descriptor
        self.path = path
        self.owner = owner
        self.fileSystem = fileSystem
    }

    /// Opens the directory at the absolute path `opening`, never through a link at its last component, named
    /// `path` in failures.
    init(
        opening absolutePath: String, path: String, owner: Installer.Owner?, fileSystem: any MutableTreeFileSystem
    ) throws(Failure) {
        let descriptor: Int32
        do { descriptor = try fileSystem.openDirectory(Array(absolutePath.utf8), in: treeRootDirectory) } catch {
            throw Failure(operation: "open", path: absolutePath, errno: Self.notADirectory(error))
        }
        self.init(descriptor: descriptor, path: path, owner: owner, fileSystem: fileSystem)
    }

    deinit {
        fileSystem.close(descriptor)
    }

    // MARK: Directories

    /// The directory `components` name below this one, open; nil when one of them is missing.
    func openDirectory(_ components: [String]) throws(Failure) -> InstallDirectory? {
        try chain(components, making: nil)
    }

    /// The directory `components` name below this one, open; each missing one made `mode` and handed to the
    /// owner.
    func makeDirectories(_ components: [String], mode: UInt16) throws(Failure) -> InstallDirectory {
        guard let directory = try chain(components, making: mode) else {
            preconditionFailure("\(path)/\(components.joined(separator: "/")) not made")
        }
        return directory
    }

    /// Hands the directory itself to its owner.
    func handToOwner() throws(Failure) {
        try hand(descriptor, path: path)
    }

    /// Hands the open `descriptor`, `path` naming it, to the owner.
    func hand(_ descriptor: Int32, path: String) throws(Failure) {
        guard let owner else { return }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure(operation: "stat", path: path, errno: errno) }
        guard info.st_uid != owner.uid || info.st_gid != owner.gid else { return }
        guard fchown(descriptor, owner.uid, owner.gid) == 0 else {
            throw Failure(operation: "chown", path: path, errno: errno)
        }
    }

    /// Flushes the directory's entries.
    func sync() throws(Failure) {
        guard fsync(descriptor) == 0 else { throw Failure(operation: "fsync", path: path, errno: errno) }
    }

    private func chain(_ components: [String], making mode: UInt16?) throws(Failure) -> InstallDirectory? {
        guard let first = components.first else { preconditionFailure("no directory below \(path) named") }
        var current = try child(first, making: mode)
        for component in components.dropFirst() {
            guard let directory = current else { return nil }
            current = try directory.child(component, making: mode)
        }
        return current
    }

    /// The directory `name` here, open; when it is missing, made `mode` and handed to the owner, or nil when
    /// `mode` is nil. A link where it belongs is refused.
    private func child(_ name: String, making mode: UInt16?) throws(Failure) -> InstallDirectory? {
        let childPath = path + "/" + name
        let bytes = Array(name.utf8)
        do { return try open(bytes, path: childPath) } catch {
            guard error.code == ENOENT else {
                throw Failure(operation: "open", path: childPath, errno: Self.notADirectory(error))
            }
        }
        guard let mode else { return nil }
        do { try fileSystem.makeDirectory(bytes, in: descriptor) } catch {
            guard error.code == EEXIST else { throw Failure(operation: "mkdir", path: childPath, errno: error.code) }
            return try opening(bytes, path: childPath)
        }
        let made = try opening(bytes, path: childPath)
        guard fchmod(made.descriptor, mode_t(mode)) == 0 else {
            throw Failure(operation: "chmod", path: childPath, errno: errno)
        }
        try hand(made.descriptor, path: childPath)
        return made
    }

    private func open(_ name: [UInt8], path: String) throws(TreeFileSystemError) -> InstallDirectory {
        InstallDirectory(
            descriptor: try fileSystem.openDirectory(name, in: descriptor), path: path, owner: owner,
            fileSystem: fileSystem)
    }

    private func opening(_ name: [UInt8], path: String) throws(Failure) -> InstallDirectory {
        do { return try open(name, path: path) } catch {
            throw Failure(operation: "open", path: path, errno: Self.notADirectory(error))
        }
    }

    /// A link where a directory belongs, refused `ELOOP`, reported as what it is to the installer: not a
    /// directory.
    private static func notADirectory(_ error: TreeFileSystemError) -> Int32 {
        error.code == ELOOP ? ENOTDIR : error.code
    }

    // MARK: Files

    /// Writes `name` here whole: `fill` writes it staged (``StagedFile``), which then replaces it with `mode`,
    /// belonging to the owner.
    public func writeFile(
        _ name: String, mode: UInt16, _ fill: (inout StagedFile<Failure>) throws(Failure) -> Void
    ) throws(Failure) {
        var file = try stage(name)
        do { try fill(&file) } catch {
            file.discard(in: self)
            throw error
        }
        try file.publish(in: self, mode: mode)
    }

    /// Begins writing `name` here whole, staged beside it, a stale staged file removed first.
    public func stage(_ name: String) throws(Failure) -> StagedFile<Failure> {
        let staged = stagedName(of: name)
        let stagedPath = path + "/" + staged
        do { try fileSystem.remove(Array(staged.utf8), in: descriptor, isDirectory: false) } catch {
            guard error.code == ENOENT else { throw Failure(operation: "remove", path: stagedPath, errno: error.code) }
        }
        let file: Int32
        do { file = try fileSystem.createFile(Array(staged.utf8), in: descriptor) } catch {
            throw Failure(operation: "create", path: stagedPath, errno: error.code)
        }
        return StagedFile(descriptor: file, name: name, path: path + "/" + name, fileSystem: fileSystem)
    }

    /// Points the link `name` here at `target`, replacing whatever entry is there in one rename, then flushes
    /// the directory.
    func replaceLink(_ name: String, target: String) throws(Failure) {
        let staged = Array(stagedName(of: name).utf8)
        let stagedPath = path + "/" + stagedName(of: name)
        do { try fileSystem.remove(staged, in: descriptor, isDirectory: false) } catch {
            guard error.code == ENOENT else { throw Failure(operation: "remove", path: stagedPath, errno: error.code) }
        }
        do { try fileSystem.makeSymlink(staged, to: Array(target.utf8), in: descriptor) } catch {
            throw Failure(operation: "symlink", path: stagedPath, errno: error.code)
        }
        do { try fileSystem.renameReplacing(staged, in: descriptor, to: Array(name.utf8), in: descriptor) } catch {
            try? fileSystem.remove(staged, in: descriptor, isDirectory: false)
            throw Failure(operation: "rename onto", path: path + "/" + name, errno: error.code)
        }
        try sync()
    }

    /// Removes `name` here, anything but a directory, a link itself: true when this call removed it, false
    /// when it was already gone.
    func removeFile(_ name: String) throws(Failure) -> Bool {
        do { try fileSystem.remove(Array(name.utf8), in: descriptor, isDirectory: false) } catch {
            guard error.code == ENOENT else {
                throw Failure(operation: "remove", path: path + "/" + name, errno: error.code)
            }
            return false
        }
        return true
    }

    /// Whether `name` is here, as anything, never followed.
    func exists(_ name: String) -> Bool {
        (try? fileSystem.status(of: Array(name.utf8), in: descriptor)) != nil
    }

    /// The bytes `name` here holds, opened without following a link.
    func contents(of name: String) throws(Failure) -> [UInt8] {
        let file = try openFile(name)
        defer { fileSystem.close(file) }
        return try read(file, path: path + "/" + name)
    }

    /// The bytes `name` here holds, opened without following a link, when `accepts` takes the status of what
    /// opened; nil when it does not.
    func contents(of name: String, accepting accepts: (FileStatus) -> Bool) throws(Failure) -> [UInt8]? {
        let file = try openFile(name)
        defer { fileSystem.close(file) }
        let status: FileStatus
        do { status = try fileSystem.status(of: file) } catch {
            throw Failure(operation: "stat", path: path + "/" + name, errno: error.code)
        }
        guard accepts(status) else { return nil }
        return try read(file, path: path + "/" + name)
    }

    private func openFile(_ name: String) throws(Failure) -> Int32 {
        do { return try fileSystem.openFile(Array(name.utf8), in: descriptor) } catch {
            throw Failure(operation: "open", path: path + "/" + name, errno: error.code)
        }
    }

    private func read(_ file: Int32, path: String) throws(Failure) -> [UInt8] {
        var bytes: [UInt8] = []
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 1)
        defer { buffer.deallocate() }
        while true {
            let count: Int
            do { count = try fileSystem.read(file, into: buffer, at: Int64(bytes.count)) } catch {
                throw Failure(operation: "read", path: path, errno: error.code)
            }
            guard count > 0 else { return bytes }
            bytes += UnsafeRawBufferPointer(rebasing: buffer[0..<count])
        }
    }
}

extension InstallDirectory where Failure == Installer.Failure {
    /// Removes `name` here, a directory with everything in it, never following a link: true when this call
    /// removed it, false when it was already gone.
    func removeTree(_ name: String) throws(Failure) -> Bool {
        guard exists(name) else { return false }
        let entryPath = path + "/" + name
        do {
            try TreeRemoval.remove(Array(name.utf8), in: descriptor, on: fileSystem)
        } catch let error as TreeFileSystemError {
            throw .system(operation: "remove", path: entryPath, errno: error.code)
        } catch {
            throw .removal(path: entryPath, detail: String(describing: error))
        }
        return true
    }
}

/// The name `name` is staged under in its directory until it is published.
func stagedName(of name: String) -> String {
    name + ".kernova-new"
}

/// A file written whole beside its destination, which it then replaces in one rename, so a reader sees the
/// old file or the new one and a running binary is never written over. The file is flushed before the rename
/// and the directory after it, so a crash leaves one or the other.
///
/// It is staged in the destination's own directory, never elsewhere and moved: a rename keeps the SELinux
/// label a file was created with, and only one created in place takes the directory's, so a binary made
/// anywhere else would land unexecutable.
public struct StagedFile<Failure: InstallFileFailure>: ~Copyable {
    /// The staged file, open for writing until it is published or discarded.
    private let file: OpenFile
    /// The destination's name in its directory.
    private let name: String
    /// The destination's path, for messages.
    private let path: String
    private let fileSystem: any MutableTreeFileSystem
    /// Where the next write lands.
    private var offset: Int64 = 0

    init(descriptor: Int32, name: String, path: String, fileSystem: any MutableTreeFileSystem) {
        file = OpenFile(descriptor: descriptor)
        self.name = name
        self.path = path
        self.fileSystem = fileSystem
    }

    /// Appends all of `bytes`.
    public mutating func write(_ bytes: UnsafeRawBufferPointer) throws(Failure) {
        var written = 0
        while written < bytes.count {
            do {
                let count = try fileSystem.write(
                    file.descriptor, from: UnsafeRawBufferPointer(rebasing: bytes[written...]), at: offset)
                written += count
                offset += Int64(count)
            } catch {
                throw Failure(operation: "write", path: stagedName(of: path), errno: error.code)
            }
        }
    }

    /// Appends all of `bytes`.
    public mutating func write(_ bytes: [UInt8]) throws(Failure) {
        // `withUnsafeBytes` rethrows untyped, so the failure comes out as a value.
        var outcome = Result<Void, Failure>.success(())
        bytes.withUnsafeBytes { buffer in outcome = Result { () throws(Failure) in try write(buffer) } }
        try outcome.get()
    }

    /// Replaces the destination in `directory` with the file written, with `mode` and belonging to the
    /// directory's owner.
    public consuming func publish(in directory: borrowing InstallDirectory<Failure>, mode: UInt16) throws(Failure) {
        _ = try publish(in: directory, mode: mode) { _ -> Never? in nil }
    }

    /// Replaces the destination in `directory` with the file written, with `mode` and belonging to the
    /// directory's owner, once `check` passes it: `check` is handed the staged file's path, closed, and answers
    /// why it is refused, or nil.
    ///
    /// - Returns: `check`'s refusal, the staged file removed and the destination left as it was; nil once the
    ///   destination is replaced.
    public consuming func publish<Refusal>(
        in directory: borrowing InstallDirectory<Failure>, mode: UInt16, check: (String) -> Refusal?
    ) throws(Failure) -> Refusal? {
        let file = self.file.release()
        let staged = Array(stagedName(of: name).utf8)
        let stagedPath = stagedName(of: path)
        do throws(Failure) {
            guard fchmod(file, mode_t(mode)) == 0 else {
                throw Failure(operation: "chmod", path: stagedPath, errno: errno)
            }
            try directory.hand(file, path: stagedPath)
            guard fsync(file) == 0 else { throw Failure(operation: "fsync", path: stagedPath, errno: errno) }
        } catch {
            fileSystem.close(file)
            try? fileSystem.remove(staged, in: directory.descriptor, isDirectory: false)
            throw error
        }
        do { try fileSystem.closeWritten(file) } catch {
            try? fileSystem.remove(staged, in: directory.descriptor, isDirectory: false)
            throw Failure(operation: "close", path: stagedPath, errno: error.code)
        }
        if let refusal = check(stagedPath) {
            try? fileSystem.remove(staged, in: directory.descriptor, isDirectory: false)
            return refusal
        }
        do {
            try fileSystem.renameReplacing(
                staged, in: directory.descriptor, to: Array(name.utf8), in: directory.descriptor)
        } catch {
            try? fileSystem.remove(staged, in: directory.descriptor, isDirectory: false)
            throw Failure(operation: "rename onto", path: path, errno: error.code)
        }
        try directory.sync()
        return nil
    }

    /// Removes the staged file from `directory`, and closes it, leaving the destination as it was.
    public consuming func discard(in directory: borrowing InstallDirectory<Failure>) {
        try? fileSystem.remove(Array(stagedName(of: name).utf8), in: directory.descriptor, isDirectory: false)
    }
}

/// A descriptor this owns alone, closed when it ends unless released first.
private struct OpenFile: ~Copyable {
    let descriptor: Int32

    deinit {
        close(descriptor)
    }

    /// The descriptor, which the caller now owns.
    consuming func release() -> Int32 {
        let descriptor = descriptor
        discard self
        return descriptor
    }
}
#endif
