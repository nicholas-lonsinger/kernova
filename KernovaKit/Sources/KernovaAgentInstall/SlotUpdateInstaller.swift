#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
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

/// The update installer of the install the agent runs from: it lands a pull's payload in the spare slot through
/// its format's ``PayloadLander``, verifies it, switches `current` to it, and — run as the new version — confirms
/// the switch (the layout and the markers are ``SlotRoot``'s).
///
/// A verified payload is switched to before the installer reports it installed, so `STAGED` means the
/// next start runs it; `onSwitched` then relaunches the process. The rollback check reverts a switch the
/// new version does not confirm.
public final class SlotUpdateInstaller: UpdateInstaller {
    private let root: SlotRoot
    private let runningSlot: String
    private let lander: any PayloadLander
    private let logger: KernovaLogger
    /// Runs once a payload is switched to and reported installed: the shell closes the connection and
    /// relaunches.
    private let onSwitched: @Sendable () -> Void
    /// Runs once this version confirmed the switch to itself.
    private let onConfirmed: @Sendable () -> Void
    private let queue: DispatchQueue
    private let state = Locked(State())

    private struct State: Sendable {
        var reporter: UpdateReporter?
        var pull: Pull?
        var confirmChecked = false
    }

    /// One pull's payload, landing.
    private struct Pull: Sendable {
        var id: UpdatePullID
        /// Nil once a write failed: the core resets the pull, and later bytes are dropped.
        var landing: (any PayloadLanding)?
        var hasher = SHA256()
        var written: UInt64 = 0
    }

    /// The installer of the install at `root` whose running version sits in `runningSlot`, landing payloads
    /// through `lander` on the serial `queue`.
    ///
    /// A switch moves `current`, reports the payload installed and runs `onSwitched` in one block on `queue`, so
    /// a watch on `current` that shares `queue` sees the move only once the report is on its way.
    public init(
        root: SlotRoot, runningSlot: String, lander: any PayloadLander, logger: KernovaLogger,
        queue: DispatchQueue = DispatchQueue(label: "app.kernova.agent.update"),
        onSwitched: @escaping @Sendable () -> Void, onConfirmed: @escaping @Sendable () -> Void = {}
    ) {
        self.queue = queue
        self.root = root
        self.runningSlot = runningSlot
        self.lander = lander
        self.logger = logger
        self.onSwitched = onSwitched
        self.onConfirmed = onConfirmed
    }

    /// The slot a payload lands in.
    var spareSlot: String { InstallState.spare(of: runningSlot) }

    // MARK: UpdateInstaller

    /// Reconciles the slot metadata with the markers and the running slot, then reports what it installs.
    public func start(reporter: UpdateReporter) {
        queue.async { [self] in
            state.withLock { $0.reporter = reporter }
            do throws(SlotRoot.Failure) {
                let reconciled = try root.reconcile(runningSlot: runningSlot)
                if let rejected = reconciled.rejected {
                    logger.log(
                        .notice, "This install refuses update payload \(rejected.payloadSHA256, privacy: .public)")
                }
                report(.availability(availability(reconciled)))
            } catch {
                logger.log(
                    .error, "Cannot read the install's slot metadata: \(String(describing: error), privacy: .public)")
                report(.availability(.absent(.unspecified, debugDetail: "slot metadata: \(error)")))
            }
        }
    }

    /// Records `hash` as the payload this install refuses.
    public func recordRejected(_ hash: Data) {
        queue.async { [self] in setRejected(InstallState.Rejection(payloadSHA256: lowercaseHex(hash))) }
    }

    /// Clears the payload this install refuses.
    public func clearRejected() {
        queue.async { [self] in setRejected(nil) }
    }

    /// Lands the pull's next bytes, beginning its landing on the first.
    public func write(_ id: UpdatePullID, _ bytes: Data) {
        queue.async { [self] in
            guard var pull = takePull(for: id), let landing = pull.landing else { return }
            do throws(SlotRoot.Failure) {
                try bytes.withUnsafeBytes { buffer throws(SlotRoot.Failure) in try landing.write(buffer) }
            } catch {
                logger.log(
                    .error,
                    "Cannot write the update payload: \(String(cString: strerror(error.errno)), privacy: .public)")
                landing.discard()
                state.withLock { $0.pull = Pull(id: id, landing: nil) }
                let code: ErrorCode = error.errno == ENOSPC ? .diskFull : .writeFailed
                return report(.failed(id, WireError(code, posixErrno: error.errno)))
            }
            bytes.withUnsafeBytes { pull.hasher.update($0) }
            pull.written += UInt64(bytes.count)
            state.withLock { $0.pull = pull }
            report(.consumed(id, bytes.count))
        }
    }

    /// Verifies the pull's payload, has it published in the spare slot, and switches to it.
    public func complete(_ id: UpdatePullID, _ manifest: UpdateManifestValue) {
        queue.async { [self] in
            guard let pull = takePull(for: id) else { return }
            state.withLock { $0.pull = nil }
            guard let landing = pull.landing else { return }
            switch install(landing, of: pull, manifest) {
            case .success:
                report(.installed(id))
                onSwitched()
            case .failure(let refusal):
                if refusal.rejectsPayload {
                    setRejected(
                        InstallState.Rejection(payloadSHA256: lowercaseHex(manifest.payloadHash), code: refusal.code))
                }
                report(.rejected(id, refusal.error))
            }
        }
    }

    /// Discards what the pull landed.
    public func abort(_ id: UpdatePullID) {
        queue.async { [self] in
            guard let pull = state.withLock({ $0.pull }), pull.id == id else { return }
            state.withLock { $0.pull = nil }
            pull.landing?.discard()
        }
    }

    // MARK: Confirmation

    /// Confirms a pending switch to this version, once per process: the agent calls it as it receives a
    /// `PolicyUpdate`, which arrives only after the host's Hello.
    public func confirm() {
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

    /// Verifies `pull`'s payload against `manifest`, has `landing` publish it in the spare slot, and switches to
    /// it. The landing is published or discarded either way.
    private func install(
        _ landing: any PayloadLanding, of pull: Pull, _ manifest: UpdateManifestValue
    ) -> Result<Void, PayloadRefusal> {
        func refuse(_ refusal: PayloadRefusal) -> Result<Void, PayloadRefusal> {
            logger.log(.error, "Refusing the update payload: \(refusal.detail, privacy: .public)")
            return .failure(refusal)
        }
        func discard(_ code: ErrorCode, _ detail: String) -> Result<Void, PayloadRefusal> {
            landing.discard()
            return refuse(PayloadRefusal(code, detail))
        }
        guard manifest.format == lander.format else {
            return discard(.updateFormatUnsupported, "format \(manifest.format)")
        }
        guard pull.written == manifest.payloadSize else {
            return discard(.updateSizeMismatch, "\(pull.written) bytes for a \(manifest.payloadSize)-byte payload")
        }
        guard Data(pull.hasher.finalize()) == manifest.payloadHash else {
            return discard(.updateHashMismatch, "the payload's SHA-256 is not the manifest's")
        }
        do throws(PayloadRefusal) { try landing.publish() } catch { return refuse(error) }
        do throws(SlotRoot.Failure) {
            try switchTo(spareSlot, manifest)
        } catch {
            undoSwitch()
            return refuse(
                PayloadRefusal(.updateInstallFailed, "switch: \(error)", errno: error.errno, rejectsPayload: false))
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
        try root.point(InstallRoot.rollbackLinkName, at: runningSlot)
        try root.remove(InstallRoot.switchRejectedName)
        try root.createSwitchPending()
        try root.point(InstallRoot.currentLinkName, at: slot)
    }

    /// Drops a switch that failed before `current` moved: no marker, no record, the running slot active.
    private func undoSwitch() {
        do throws(SlotRoot.Failure) {
            try root.point(InstallRoot.currentLinkName, at: runningSlot)
            try root.remove(InstallRoot.switchPendingName)
            var current = try root.readState()
            current.pendingSwitch = nil
            current.active = runningSlot
            try root.writeState(current)
        } catch {
            logger.log(.error, "Cannot undo the failed switch: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Helpers

    /// The pull `id` names: the open one, or — with none open for it — a new one, its landing begun in the spare
    /// slot, after any other is discarded. Nil when it cannot begin, having reported why.
    private func takePull(for id: UpdatePullID) -> Pull? {
        if let pull = state.withLock({ $0.pull }), pull.id == id { return pull }
        if let stale = state.withLock({ $0.pull }) { stale.landing?.discard() }
        state.withLock { $0.pull = nil }
        do throws(SlotRoot.Failure) {
            let pull = Pull(id: id, landing: try lander.beginUpdate(in: spareSlot, of: root))
            state.withLock { $0.pull = pull }
            return pull
        } catch {
            logger.log(.error, "Cannot stage the update payload: \(String(describing: error), privacy: .public)")
            state.withLock { $0.pull = Pull(id: id, landing: nil) }
            let code: ErrorCode = error.errno == ENOSPC ? .diskFull : .writeFailed
            report(.failed(id, WireError(code, posixErrno: error.errno)))
            return nil
        }
    }

    private func setRejected(_ rejection: InstallState.Rejection?) {
        do throws(SlotRoot.Failure) {
            var current = try root.readState()
            guard current.rejected != rejection else { return }
            current.rejected = rejection
            try root.writeState(current)
            report(.availability(availability(current)))
        } catch {
            logger.log(
                .error, "Cannot record the rejected update payload: \(String(describing: error), privacy: .public)")
        }
    }

    private func report(_ input: UpdateInput) {
        state.withLock { $0.reporter }?.report(input)
    }

    /// What the installer advertises for `state`: the one format its lander lands, and the payload it refuses.
    private func availability(_ state: InstallState) -> Availability<UpdateOffer> {
        let rejected = state.rejected.flatMap { rejection in
            bytes(fromHex: rejection.payloadSHA256).map { RejectedPayload(hash: Data($0), code: rejection.code) }
        }
        return .available(UpdateOffer(formats: [lander.format], rejected: rejected))
    }
}
#endif
