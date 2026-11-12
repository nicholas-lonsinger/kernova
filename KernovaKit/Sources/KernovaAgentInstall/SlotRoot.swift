#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import KernovaFileTree

/// One install's root, open, as the agent that runs from it and its rollback check change it: `state.json`,
/// the `current` and `rollback` links, the slots, and the two switch markers, each reached through the root's
/// ``InstallDirectory``.
///
/// Each file has one writer, so no two processes ever write one file: the running agent writes `state.json`
/// and creates `switch-pending`; the rollback check appends to `switch-pending` and only reads `state.json`.
/// Which of them settles an update's switch is decided by `switch-pending` alone: the new version confirms
/// it by removing it, the rollback check reverts it by renaming it to `switch-rejected`, and of the two calls
/// on that one name exactly one succeeds. The agent then folds `switch-rejected` into `state.json` when it
/// next starts (``reconcile(runningSlot:)``).
public final class SlotRoot: Sendable {
    /// What failed, and where.
    public struct Failure: InstallFileFailure, CustomStringConvertible, Equatable {
        /// The call that failed.
        public var operation: String
        /// The full path it acted on.
        public var path: String
        /// Its errno; 0 when the failure was not a call's, as for metadata that does not parse.
        public var errno: Int32
        /// What failed, when `errno` is 0.
        public var detail: String

        /// `operation` on `path` failing with `errno`, or with `detail` when `errno` is 0.
        public init(operation: String, path: String, errno: Int32, detail: String) {
            self.operation = operation
            self.path = path
            self.errno = errno
            self.detail = detail
        }

        /// `operation` on `path` failing with `errno`.
        public init(operation: String, path: String, errno: Int32) {
            self.init(operation: operation, path: path, errno: errno, detail: "")
        }

        /// The call, the path, and the OS's message for the errno or the detail.
        public var description: String {
            errno == 0 ? "\(operation) \(path): \(detail)" : "\(operation) \(path): \(String(cString: strerror(errno)))"
        }
    }

    private let root: InstallDirectory<Failure>

    /// The root's path, for messages.
    public var path: String { root.path }

    /// The root at `path`, a path `realpath(3)` gives, opened through `fileSystem`.
    public init(path: String, fileSystem: any MutableTreeFileSystem = POSIXTreeFileSystem()) throws(Failure) {
        root = try InstallDirectory(opening: path, path: path, owner: nil, fileSystem: fileSystem)
    }

    // MARK: state.json

    /// The slot metadata.
    func readState() throws(Failure) -> InstallState {
        let bytes = try root.contents(of: InstallRoot.stateName)
        do {
            return try InstallState.decoded(bytes)
        } catch {
            throw Failure(operation: "parse", path: statePath, errno: 0, detail: "\(error)")
        }
    }

    /// The SHA-256 of the payload the slot metadata records `slot` holding, lowercase hex: the identity the
    /// agent running from it claims. Nil when it records none there.
    public func payloadSHA256(ofSlot slot: String) throws(Failure) -> String? {
        try readState().slots[slot]?.payloadSHA256
    }

    /// Replaces the slot metadata whole.
    func writeState(_ state: InstallState) throws(Failure) {
        let bytes: [UInt8]
        do { bytes = try state.encoded() } catch {
            throw Failure(operation: "encode", path: statePath, errno: 0, detail: "\(error)")
        }
        try root.writeFile(InstallRoot.stateName, mode: 0o644) { file throws(Failure) in try file.write(bytes) }
    }

    private var statePath: String { path + "/" + InstallRoot.stateName }

    // MARK: Links

    /// Points the link `name` at `slots/<slot>`, replacing it in one rename.
    func point(_ name: String, at slot: String) throws(Failure) {
        try root.replaceLink(name, target: InstallRoot.slotsName + "/" + slot)
    }

    /// The slot the link `name`, relative to the directory open at `directory` — ``treeRootDirectory`` for a
    /// path — points at, `slots/<slot>`; nil when it is missing or points elsewhere.
    public static func slot(
        linkedFrom name: String, in directory: Int32, on fileSystem: any TreeFileSystem = POSIXTreeFileSystem()
    ) -> String? {
        guard let target = try? fileSystem.linkTarget(of: Array(name.utf8), in: directory) else { return nil }
        let prefix = Array((InstallRoot.slotsName + "/").utf8)
        guard target.starts(with: prefix) else { return nil }
        let slot = target.dropFirst(prefix.count)
        guard !slot.isEmpty, !slot.contains(UInt8(ascii: "/")) else { return nil }
        return String(decoding: slot, as: UTF8.self)
    }

    // MARK: Markers

    /// Whether `name` exists, as a file or anything else.
    func exists(_ name: String) -> Bool {
        root.exists(name)
    }

    /// Makes `switch-pending` empty, replacing it whole: no run of the rollback check has counted against the
    /// switch yet.
    func createSwitchPending() throws(Failure) {
        try root.writeFile(InstallRoot.switchPendingName, mode: 0o644) { _ throws(Failure) in }
    }

    /// Counts one run of the rollback check against the pending switch, by appending a byte to
    /// `switch-pending`, and answers how many runs have counted; nil when there is no pending switch. The
    /// marker is never created here, so a switch confirmed meanwhile is never brought back.
    func countRollbackRun() throws(Failure) -> Int? {
        let name = InstallRoot.switchPendingName
        let markerPath = path + "/" + name
        let file: Int32
        do { file = try root.fileSystem.openFileForAppending(Array(name.utf8), in: root.descriptor) } catch {
            guard error.code == ENOENT else { throw Failure(operation: "open", path: markerPath, errno: error.code) }
            return nil
        }
        defer { root.fileSystem.close(file) }
        var run: UInt8 = 0x2E
        while write(file, &run, 1) != 1 {
            guard errno == EINTR else { throw Failure(operation: "write", path: markerPath, errno: errno) }
        }
        do { return Int(try root.fileSystem.status(of: file).size) } catch {
            throw Failure(operation: "stat", path: markerPath, errno: error.code)
        }
    }

    /// Takes `switch-pending` away for the agent, settling the switch without a rollback; false when it is
    /// gone already, as a rollback check that reverted the switch leaves it.
    func takeSwitchPending() throws(Failure) -> Bool {
        try remove(InstallRoot.switchPendingName)
    }

    /// Takes `switch-pending` away for the rollback check, renaming it `switch-rejected`; false when it is gone
    /// already, as the new version's confirmation leaves it.
    func claimRollback() throws(Failure) -> Bool {
        do {
            try root.fileSystem.renameReplacing(
                Array(InstallRoot.switchPendingName.utf8), in: root.descriptor,
                to: Array(InstallRoot.switchRejectedName.utf8), in: root.descriptor)
        } catch {
            guard error.code == ENOENT else {
                throw Failure(
                    operation: "rename", path: path + "/" + InstallRoot.switchPendingName, errno: error.code)
            }
            return false
        }
        try root.sync()
        return true
    }

    /// Removes the file `name`: true when this call removed it, false when it was already gone.
    @discardableResult
    func remove(_ name: String) throws(Failure) -> Bool {
        guard try root.removeFile(name) else { return false }
        try root.sync()
        return true
    }

    // MARK: Slots

    /// The directory `slots/<slot>`, open; made first when it is missing.
    public func openSlot(_ slot: String) throws(Failure) -> InstallDirectory<Failure> {
        try root.makeDirectories([InstallRoot.slotsName, slot], mode: 0o755)
    }

    // MARK: Reconciling

    /// Brings `state.json` up to what the markers and the running slot say, as the agent running from
    /// `runningSlot` starts: a switch the rollback check reverted records its payload as rejected; a switch
    /// whose marker is gone was confirmed; a pending switch to another slot than the running one never took
    /// effect and is dropped; and the running slot is the active one. Answers the state as written.
    func reconcile(runningSlot: String) throws(Failure) -> InstallState {
        var state = try readState()
        let before = state
        if exists(InstallRoot.switchRejectedName) {
            if let reverted = state.pendingSwitch { state.rejected = .init(payloadSHA256: reverted.payloadSHA256) }
            state.pendingSwitch = nil
        } else if let pending = state.pendingSwitch {
            if !exists(InstallRoot.switchPendingName) {
                state.pendingSwitch = nil
            } else if pending.to != runningSlot {
                if try takeSwitchPending() {
                    state.pendingSwitch = nil
                } else if exists(InstallRoot.switchRejectedName) {
                    // The rollback check reverted it between the two looks.
                    state.rejected = .init(payloadSHA256: pending.payloadSHA256)
                    state.pendingSwitch = nil
                }
            }
        }
        state.active = runningSlot
        if state != before { try writeState(state) }
        try remove(InstallRoot.switchRejectedName)
        return state
    }
}
#endif
