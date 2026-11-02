#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One install's root, open, as the agent that runs from it and its rollback check change it: `state.json`,
/// the `current` and `rollback` links, the slots, and the two switch markers. Every name is reached relative
/// to the root's descriptor.
///
/// Each file has one writer, so no two processes ever write one file: the running agent writes `state.json`
/// and creates `switch-pending`; the rollback check appends to `switch-pending` and only reads `state.json`.
/// Which of them settles an update's switch is decided by `switch-pending` alone: the new version confirms
/// it by removing it, the rollback check reverts it by renaming it to `switch-rejected`, and of the two calls
/// on that one name exactly one succeeds. The agent then folds `switch-rejected` into `state.json` when it
/// next starts (``reconcile(runningSlot:)``).
final class SlotRoot: Sendable {
    /// What failed, and where.
    struct Failure: Error, CustomStringConvertible, Equatable {
        /// The call that failed.
        var operation: String
        /// The name it acted on, relative to the root.
        var name: String
        /// Its errno; 0 when the failure was not a call's, as for metadata that does not parse.
        var errno: Int32
        /// What failed, when `errno` is 0.
        var detail = ""

        var description: String {
            errno == 0 ? "\(operation) \(name): \(detail)" : "\(operation) \(name): \(String(cString: strerror(errno)))"
        }
    }

    /// The root's path, for messages.
    let path: String
    private let descriptor: Int32

    /// The root at `path`, opened as a directory.
    init(path: String) throws(Failure) {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure(operation: "open", name: path, errno: errno) }
        self.path = path
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    // MARK: state.json

    /// The slot metadata.
    func readState() throws(Failure) -> InstallState {
        let bytes = try contents(of: InstallLayout.stateName)
        do {
            return try InstallState.decoded(bytes)
        } catch {
            throw Failure(operation: "parse", name: InstallLayout.stateName, errno: 0, detail: "\(error)")
        }
    }

    /// Replaces the slot metadata whole and durably: written beside it, flushed, renamed over it, then the
    /// directory flushed, so a crash leaves the old file or the new one.
    func writeState(_ state: InstallState) throws(Failure) {
        let bytes: [UInt8]
        do { bytes = try state.encoded() } catch {
            throw Failure(operation: "encode", name: InstallLayout.stateName, errno: 0, detail: "\(error)")
        }
        let temporary = InstallLayout.stateName + ".tmp"
        let file = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { throw Failure(operation: "create", name: temporary, errno: errno) }
        do throws(Failure) {
            try Self.writeAll(bytes, to: file, name: temporary)
            guard fsync(file) == 0 else { throw Failure(operation: "fsync", name: temporary, errno: errno) }
        } catch {
            close(file)
            unlinkat(descriptor, temporary, 0)
            throw error
        }
        close(file)
        guard renameat(descriptor, temporary, descriptor, InstallLayout.stateName) == 0 else {
            let failure = errno
            unlinkat(descriptor, temporary, 0)
            throw Failure(operation: "rename onto", name: InstallLayout.stateName, errno: failure)
        }
        try syncDirectory()
    }

    // MARK: Links

    /// Points the link `name` at `slots/<slot>`, replacing it in one rename.
    func point(_ name: String, at slot: String) throws(Failure) {
        let temporary = name + ".kernova-new"
        guard unlinkat(descriptor, temporary, 0) == 0 || errno == ENOENT else {
            throw Failure(operation: "remove", name: temporary, errno: errno)
        }
        guard symlinkat("slots/" + slot, descriptor, temporary) == 0 else {
            throw Failure(operation: "symlink", name: temporary, errno: errno)
        }
        guard renameat(descriptor, temporary, descriptor, name) == 0 else {
            let failure = errno
            unlinkat(descriptor, temporary, 0)
            throw Failure(operation: "rename onto", name: name, errno: failure)
        }
        try syncDirectory()
    }

    /// The slot the link `name` points at, `slots/<slot>`; nil when it is missing or points elsewhere.
    func slot(linkedFrom name: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let count = readlinkat(descriptor, name, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        let target = String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard target.hasPrefix("slots/") else { return nil }
        let slot = String(target.dropFirst("slots/".count))
        return slot.isEmpty || slot.contains("/") ? nil : slot
    }

    // MARK: Markers

    /// Whether `name` exists, as a file or anything else.
    func exists(_ name: String) -> Bool {
        var info = stat()
        return fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    /// Makes `switch-pending` empty: no run of the rollback check has counted against the switch yet.
    func createSwitchPending() throws(Failure) {
        let name = InstallLayout.switchPendingName
        let file = openat(descriptor, name, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { throw Failure(operation: "create", name: name, errno: errno) }
        let synced = fsync(file) == 0
        let failure = errno
        close(file)
        guard synced else { throw Failure(operation: "fsync", name: name, errno: failure) }
        try syncDirectory()
    }

    /// Counts one run of the rollback check against the pending switch, by appending a byte to
    /// `switch-pending`, and answers how many runs have counted; nil when there is no pending switch. The
    /// marker is opened without `O_CREAT`, so a switch confirmed meanwhile is never brought back.
    func countRollbackRun() throws(Failure) -> Int? {
        let name = InstallLayout.switchPendingName
        let file = openat(descriptor, name, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else {
            guard errno == ENOENT else { throw Failure(operation: "open", name: name, errno: errno) }
            return nil
        }
        defer { close(file) }
        try Self.writeAll([0x2E], to: file, name: name)
        var info = stat()
        guard fstat(file, &info) == 0 else { throw Failure(operation: "stat", name: name, errno: errno) }
        return Int(info.st_size)
    }

    /// Takes `switch-pending` away for the agent, settling the switch without a rollback; false when it is
    /// gone already, as a rollback check that reverted the switch leaves it.
    func takeSwitchPending() throws(Failure) -> Bool {
        try remove(InstallLayout.switchPendingName)
    }

    /// Takes `switch-pending` away for the rollback check, renaming it `switch-rejected`; false when it is gone
    /// already, as the new version's confirmation leaves it.
    func claimRollback() throws(Failure) -> Bool {
        guard
            renameat(descriptor, InstallLayout.switchPendingName, descriptor, InstallLayout.switchRejectedName) == 0
        else {
            guard errno == ENOENT else {
                throw Failure(operation: "rename", name: InstallLayout.switchPendingName, errno: errno)
            }
            return false
        }
        try syncDirectory()
        return true
    }

    /// Removes the file `name`: true when this call removed it, false when it was already gone.
    @discardableResult
    func remove(_ name: String) throws(Failure) -> Bool {
        guard unlinkat(descriptor, name, 0) == 0 else {
            guard errno == ENOENT else { throw Failure(operation: "remove", name: name, errno: errno) }
            return false
        }
        try syncDirectory()
        return true
    }

    // MARK: Slots

    /// The directory `slots/<slot>`, open; made first when it is missing.
    func openSlot(_ slot: String) throws(Failure) -> Int32 {
        let name = "slots/" + slot
        if mkdirat(descriptor, name, 0o755) != 0, errno != EEXIST {
            throw Failure(operation: "mkdir", name: name, errno: errno)
        }
        let directory = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure(operation: "open", name: name, errno: errno) }
        return directory
    }

    // MARK: Reconciling

    /// Brings `state.json` up to what the markers and the running slot say, as the agent running from
    /// `runningSlot` starts: a switch the rollback check reverted records its payload as rejected; a switch
    /// whose marker is gone was confirmed; a pending switch to another slot than the running one never took
    /// effect and is dropped; and the running slot is the active one. Answers the state as written.
    func reconcile(runningSlot: String) throws(Failure) -> InstallState {
        var state = try readState()
        let before = state
        if exists(InstallLayout.switchRejectedName) {
            if let reverted = state.pendingSwitch { state.rejectedSHA256 = reverted.payloadSHA256 }
            state.pendingSwitch = nil
        } else if let pending = state.pendingSwitch {
            if !exists(InstallLayout.switchPendingName) {
                state.pendingSwitch = nil
            } else if pending.to != runningSlot {
                if try takeSwitchPending() {
                    state.pendingSwitch = nil
                } else if exists(InstallLayout.switchRejectedName) {
                    // The rollback check reverted it between the two looks.
                    state.rejectedSHA256 = pending.payloadSHA256
                    state.pendingSwitch = nil
                }
            }
        }
        state.active = runningSlot
        if state != before { try writeState(state) }
        try remove(InstallLayout.switchRejectedName)
        return state
    }

    // MARK: Helpers

    private func contents(of name: String) throws(Failure) -> [UInt8] {
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw Failure(operation: "open", name: name, errno: errno) }
        defer { close(file) }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Failure(operation: "read", name: name, errno: errno) }
            guard count > 0 else { return bytes }
            bytes += buffer[0..<count]
        }
    }

    private func syncDirectory() throws(Failure) {
        guard fsync(descriptor) == 0 else { throw Failure(operation: "fsync", name: ".", errno: errno) }
    }

    static func writeAll(_ bytes: [UInt8], to file: Int32, name: String) throws(Failure) {
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { write(file, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw Failure(operation: "write", name: name, errno: errno) }
            offset += count
        }
    }
}
#endif
