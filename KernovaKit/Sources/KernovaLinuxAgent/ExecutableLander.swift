#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import KernovaAgentCore
import KernovaAgentInstall
import KernovaWire

/// The lander of `PAYLOAD_FORMAT_EXECUTABLE`: the static `kernova-agent`, one executable file in its slot, written
/// whole as a ``StagedFile`` there.
struct ExecutableLander: PayloadLander {
    /// The calls the lander makes into the system, replaced in tests.
    struct System: Sendable {
        /// Runs the staged binary at a path through its `self-test`.
        var selfTest: @Sendable (String) -> SelfTest.Outcome = { SelfTest.run($0) }
    }

    var system = System()

    var format: PayloadFormat { .executable }

    func install(
        _ payload: InstallPayloadReader, as name: String, in slot: borrowing InstallDirectory<Installer.Failure>
    ) throws(Installer.Failure) {
        try slot.writeFile(name, mode: 0o755) { file throws(Installer.Failure) in
            try payload.read { piece throws(Installer.Failure) in try file.write(piece) }
        }
    }

    func beginUpdate(in slot: String, of root: SlotRoot) throws(SlotRoot.Failure) -> any PayloadLanding {
        let directory = try root.openSlot(slot)
        let file = try directory.stage(InstallLayout.binaryName)
        return Landing(system: system, slot: directory, file: file)
    }

    /// One update, staged in the slot until it is published as the slot's binary. ``SlotUpdateInstaller`` calls
    /// it from its own queue alone, one call at a time, which is what makes its unsynchronized state safe to
    /// share.
    final class Landing: PayloadLanding, @unchecked Sendable {
        private let system: System
        /// The slot, open.
        private let slot: InstallDirectory<SlotRoot.Failure>
        /// The staged binary until the landing publishes or is discarded.
        private var file: StagedFile<SlotRoot.Failure>?

        init(
            system: System, slot: consuming InstallDirectory<SlotRoot.Failure>,
            file: consuming StagedFile<SlotRoot.Failure>
        ) {
            self.system = system
            self.slot = slot
            self.file = .some(file)
        }

        func write(_ bytes: UnsafeRawBufferPointer) throws(SlotRoot.Failure) {
            guard file != nil else { preconditionFailure("bytes after the landing ended") }
            try file?.write(bytes)
        }

        /// Publishes the staged binary as the slot's, made executable, once its self-test passes.
        func publish() throws(PayloadRefusal) {
            guard let file = file.take() else { preconditionFailure("a publish after the landing ended") }
            let refusal: PayloadRefusal?
            do {
                refusal = try file.publish(in: slot, mode: 0o755) { [system] staged in
                    let outcome = system.selfTest(staged)
                    return outcome == .passed ? nil : PayloadRefusal(.updateInstallFailed, "self-test: \(outcome)")
                }
            } catch {
                throw PayloadRefusal(
                    .updateInstallFailed, "\(error.operation) \(error.path)", errno: error.errno, rejectsPayload: false)
            }
            if let refusal { throw refusal }
        }

        func discard() {
            file.take()?.discard(in: slot)
        }
    }
}
#endif
