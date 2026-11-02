#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Apple's Dispatch marks its source protocols `Sendable`; swift-corelibs-libdispatch does not.
@preconcurrency import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaDigest
import KernovaLogging
import KernovaSynchronization
import KernovaWire

/// The Linux agent's update installer, for the install its executable runs from: it writes a pull's payload
/// into the spare slot, verifies it, switches `current` to it, and — run as the new version — confirms the
/// switch (spec §8.4; the layout and the markers are ``SlotRoot``'s).
///
/// A verified payload is switched to before the installer reports it installed, so `STAGED` means the
/// next start runs it; ``onSwitched`` then relaunches the process. The rollback check reverts a switch the
/// new version does not confirm.
final class LinuxUpdateInstaller: UpdateInstaller {
    /// The calls the installer makes into the system, replaced in tests.
    struct System: Sendable {
        /// Runs the staged binary at a path through its `self-test`.
        var selfTest: @Sendable (String) -> SelfTest.Outcome = { SelfTest.run($0) }
        /// write(2).
        var write: @Sendable (Int32, UnsafeRawBufferPointer) -> Int = posixWrite
    }

    /// The staged payload's name in the spare slot, until it is verified.
    static let partialName = InstallLayout.binaryName + ".partial"

    private let root: SlotRoot
    private let runningSlot: String
    private let system: System
    private let logger: KernovaLogger
    /// Runs once a payload is switched to and reported installed: the shell closes the connection and
    /// relaunches.
    private let onSwitched: @Sendable () -> Void
    /// Runs once this version confirmed the switch to itself.
    private let onConfirmed: @Sendable () -> Void
    private let queue = DispatchQueue(label: "app.kernova.agent.update")
    private let state = Locked(State())

    private struct State: Sendable {
        var reporter: UpdateReporter?
        var pull: Pull?
        var confirmChecked = false
    }

    /// One pull's staged payload, open.
    private struct Pull: Sendable {
        var id: UpdatePullID
        var slot: Int32
        var file: Int32
        var hasher = SHA256()
        var written: UInt64 = 0
        /// A write failed; the core resets the pull, and later bytes are dropped.
        var failed = false
    }

    /// The installer of the install at `root` whose running version sits in `runningSlot`.
    init(
        root: SlotRoot, runningSlot: String, system: System = System(), logger: KernovaLogger,
        onSwitched: @escaping @Sendable () -> Void, onConfirmed: @escaping @Sendable () -> Void = {}
    ) {
        self.root = root
        self.runningSlot = runningSlot
        self.system = system
        self.logger = logger
        self.onSwitched = onSwitched
        self.onConfirmed = onConfirmed
    }

    /// The slot a payload is staged in.
    var spareSlot: String { InstallState.spare(of: runningSlot) }

    // MARK: UpdateInstaller

    func start(reporter: UpdateReporter) {
        queue.async { [self] in
            state.withLock { $0.reporter = reporter }
            do throws(SlotRoot.Failure) {
                let reconciled = try root.reconcile(runningSlot: runningSlot)
                if let rejected = reconciled.rejectedSHA256 {
                    logger.log(.notice, "This install refuses update payload \(rejected, privacy: .public)")
                }
                report(.availability(Self.availability(reconciled)))
            } catch {
                logger.log(
                    .error, "Cannot read the install's slot metadata: \(String(describing: error), privacy: .public)")
                report(.availability(.absent(.unspecified, debugDetail: "slot metadata: \(error)")))
            }
        }
    }

    func recordRejected(_ hash: Data) {
        queue.async { [self] in setRejected(lowercaseHex(hash)) }
    }

    func clearRejected() {
        queue.async { [self] in setRejected(nil) }
    }

    func write(_ id: UpdatePullID, _ bytes: Data) {
        queue.async { [self] in
            guard var pull = takePull(for: id), !pull.failed else { return }
            let failure = bytes.withUnsafeBytes { buffer -> Int32? in
                var offset = 0
                while offset < buffer.count {
                    let count = system.write(pull.file, UnsafeRawBufferPointer(rebasing: buffer[offset...]))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return count < 0 ? errno : EIO }
                    offset += count
                }
                return nil
            }
            if let failure {
                logger.log(
                    .error, "Cannot write the update payload: \(String(cString: strerror(failure)), privacy: .public)")
                pull.failed = true
                discard(pull)
                state.withLock { $0.pull = Pull(id: id, slot: -1, file: -1, failed: true) }
                let code: ErrorCode = failure == ENOSPC ? .diskFull : .writeFailed
                return report(.failed(id, WireError(code, posixErrno: failure)))
            }
            bytes.withUnsafeBytes { pull.hasher.update($0) }
            pull.written += UInt64(bytes.count)
            state.withLock { $0.pull = pull }
            report(.consumed(id, bytes.count))
        }
    }

    func complete(_ id: UpdatePullID, _ manifest: UpdateManifestValue) {
        queue.async { [self] in
            guard let pull = takePull(for: id) else { return }
            state.withLock { $0.pull = nil }
            guard !pull.failed else { return }
            switch install(pull, manifest) {
            case .success:
                report(.installed(id))
                onSwitched()
            case .failure(let refusal):
                if refusal.rejectsPayload { setRejected(lowercaseHex(manifest.payloadHash)) }
                report(.rejected(id, refusal.error))
            }
        }
    }

    func abort(_ id: UpdatePullID) {
        queue.async { [self] in
            guard let pull = state.withLock({ $0.pull }), pull.id == id else { return }
            state.withLock { $0.pull = nil }
            discard(pull)
        }
    }

    // MARK: Confirmation

    /// Confirms a pending switch to this version, once per process: the agent calls it as it receives a
    /// `PolicyUpdate`, which arrives only after the host's Hello.
    func confirm() {
        queue.async { [self] in
            guard !state.withLock({ $0.confirmChecked }) else { return }
            state.withLock { $0.confirmChecked = true }
            do throws(SlotRoot.Failure) {
                var current = try root.readState()
                guard let pending = current.pendingSwitch, pending.to == runningSlot else { return }
                guard try root.takeSwitchPending() else {
                    return logger.log(.error, "The rollback check reverted this update before it connected")
                }
                current.pendingSwitch = nil
                try root.writeState(current)
                logger.log(.notice, "The update to slot \(runningSlot, privacy: .public) is confirmed")
            } catch {
                return logger.log(.error, "Cannot confirm the update: \(String(describing: error), privacy: .public)")
            }
            onConfirmed()
        }
    }

    // MARK: Installing

    /// Why a payload was not installed.
    private struct Refusal: Error {
        var error: WireError
        /// The payload itself is at fault, so the install records it as rejected.
        var rejectsPayload: Bool
    }

    /// Verifies the staged payload against `manifest`, runs its self-test, moves it into the spare slot and
    /// switches to it. Closes what `pull` holds open, and removes the staged file it does not install.
    private func install(_ pull: Pull, _ manifest: UpdateManifestValue) -> Result<Void, Refusal> {
        var file = pull.file
        defer {
            if file >= 0 { close(file) }
            close(pull.slot)
        }
        func refuse(_ code: ErrorCode, _ detail: String, errno: Int32 = 0, rejects: Bool = true) -> Result<
            Void, Refusal
        > {
            unlinkat(pull.slot, Self.partialName, 0)
            logger.log(.error, "Refusing the update payload: \(detail, privacy: .public)")
            let error = WireError(code, posixErrno: errno, debugDetail: detail)
            return .failure(Refusal(error: error, rejectsPayload: rejects))
        }
        guard manifest.format == .executable else {
            return refuse(.updateFormatUnsupported, "format \(manifest.format)")
        }
        guard fsync(pull.file) == 0 else { return refuse(.updateInstallFailed, "fsync", errno: errno, rejects: false) }
        guard pull.written == manifest.payloadSize else {
            return refuse(.updateSizeMismatch, "\(pull.written) bytes for a \(manifest.payloadSize)-byte payload")
        }
        guard Data(pull.hasher.finalize()) == manifest.payloadHash else {
            return refuse(.updateHashMismatch, "the payload's SHA-256 is not the manifest's")
        }
        guard fchmod(pull.file, 0o755) == 0 else {
            return refuse(.updateInstallFailed, "chmod", errno: errno, rejects: false)
        }
        let staged = root.path + "/slots/" + spareSlot + "/" + Self.partialName
        // Closed first: a file open for writing cannot be executed (ETXTBSY).
        close(file)
        file = -1
        let outcome = system.selfTest(staged)
        guard outcome == .passed else { return refuse(.updateInstallFailed, "self-test: \(outcome)") }
        guard renameat(pull.slot, Self.partialName, pull.slot, InstallLayout.binaryName) == 0, fsync(pull.slot) == 0
        else { return refuse(.updateInstallFailed, "rename into the slot", errno: errno, rejects: false) }
        do throws(SlotRoot.Failure) {
            try switchTo(spareSlot, manifest)
        } catch {
            undoSwitch()
            return refuse(.updateInstallFailed, "switch: \(error)", errno: error.errno, rejects: false)
        }
        logger.log(
            .notice,
            "Switched to update \(manifest.versionLabel, privacy: .public) in slot \(spareSlot, privacy: .public)")
        return .success(())
    }

    /// Records the switch from the running slot to `slot`, points `rollback` at the running slot, marks the
    /// switch pending, then points `current` at `slot`, last, so every earlier step is undone by dropping the
    /// switch.
    private func switchTo(_ slot: String, _ manifest: UpdateManifestValue) throws(SlotRoot.Failure) {
        var next = try root.readState()
        let hash = lowercaseHex(manifest.payloadHash)
        next.slots[slot] = InstallState.Slot(payloadSHA256: hash, versionLabel: manifest.versionLabel)
        next.pendingSwitch = InstallState.Switch(from: runningSlot, to: slot, payloadSHA256: hash)
        next.active = slot
        try root.writeState(next)
        try root.point(InstallLayout.rollbackLinkName, at: runningSlot)
        try root.remove(InstallLayout.switchRejectedName)
        try root.createSwitchPending()
        try root.point(InstallLayout.currentLinkName, at: slot)
    }

    /// Drops a switch that failed before `current` moved: no marker, no record, the running slot active.
    private func undoSwitch() {
        do throws(SlotRoot.Failure) {
            try root.point(InstallLayout.currentLinkName, at: runningSlot)
            try root.remove(InstallLayout.switchPendingName)
            var current = try root.readState()
            current.pendingSwitch = nil
            current.active = runningSlot
            try root.writeState(current)
        } catch {
            logger.log(.error, "Cannot undo the failed switch: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Helpers

    /// The pull `id` names: the open one, or — with none open for it — a new one, its staged file created
    /// empty, after any other is discarded. Nil when it cannot be opened, having reported why.
    private func takePull(for id: UpdatePullID) -> Pull? {
        if let pull = state.withLock({ $0.pull }), pull.id == id { return pull }
        if let stale = state.withLock({ $0.pull }) { discard(stale) }
        state.withLock { $0.pull = nil }
        do throws(SlotRoot.Failure) {
            let slot = try root.openSlot(spareSlot)
            let file = openat(
                slot, Self.partialName, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o700)
            guard file >= 0 else {
                let failure = errno
                close(slot)
                throw SlotRoot.Failure(operation: "create", name: Self.partialName, errno: failure)
            }
            let pull = Pull(id: id, slot: slot, file: file)
            state.withLock { $0.pull = pull }
            return pull
        } catch {
            logger.log(.error, "Cannot stage the update payload: \(String(describing: error), privacy: .public)")
            state.withLock { $0.pull = Pull(id: id, slot: -1, file: -1, failed: true) }
            let code: ErrorCode = error.errno == ENOSPC ? .diskFull : .writeFailed
            report(.failed(id, WireError(code, posixErrno: error.errno)))
            return nil
        }
    }

    /// Closes what `pull` holds open and removes its staged file.
    private func discard(_ pull: Pull) {
        if pull.file >= 0 { close(pull.file) }
        if pull.slot >= 0 {
            unlinkat(pull.slot, Self.partialName, 0)
            close(pull.slot)
        }
    }

    private func setRejected(_ hash: String?) {
        do throws(SlotRoot.Failure) {
            var current = try root.readState()
            guard current.rejectedSHA256 != hash else { return }
            current.rejectedSHA256 = hash
            try root.writeState(current)
            report(.availability(Self.availability(current)))
        } catch {
            logger.log(
                .error, "Cannot record the rejected update payload: \(String(describing: error), privacy: .public)")
        }
    }

    private func report(_ input: UpdateInput) {
        state.withLock { $0.reporter }?.report(input)
    }

    /// What the installer advertises for `state`: the one format it installs, and the hash it refuses.
    static func availability(_ state: InstallState) -> Availability<UpdateOffer> {
        .available(
            UpdateOffer(
                formats: [.executable], rejectedHash: state.rejectedSHA256.flatMap(bytes(fromHex:)).map { Data($0) }))
    }
}
/// write(2) of `buffer` to `file`.
private func posixWrite(_ file: Int32, _ buffer: UnsafeRawBufferPointer) -> Int {
    write(file, buffer.baseAddress, buffer.count)
}
#endif
