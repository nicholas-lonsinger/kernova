#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import KernovaAgentCore
import KernovaAgentInstall
import KernovaWire

/// The lander of `PAYLOAD_FORMAT_EXECUTABLE`: the static `kernova-agent`, one executable file in its slot. An update
/// is staged in the slot itself, for the reason the installer makes every file beside its destination
/// (`Installer.writeFile`).
struct ExecutableLander: PayloadLander {
    /// The calls the lander makes into the system, replaced in tests.
    struct System: Sendable {
        /// Runs the staged binary at a path through its `self-test`.
        var selfTest: @Sendable (String) -> SelfTest.Outcome = { SelfTest.run($0) }
        /// write(2).
        var write: @Sendable (Int32, UnsafeRawBufferPointer) -> Int = posixWrite
    }

    /// An update's name in the slot until it is published.
    static let partialName = InstallLayout.binaryName + ".partial"

    var system = System()

    var format: PayloadFormat { .executable }

    func install(_ payload: InstallPayloadReader, as name: String, in slot: InstallDirectory) throws(Installer.Failure)
    {
        let path = slot.path + "/" + name
        try slot.writeFile(name, mode: 0o755) { descriptor throws(Installer.Failure) in
            while let piece = try payload.next() {
                try Installer.writeAll(Array(piece), to: descriptor, path: path)
            }
        }
    }

    func beginUpdate(in slot: String, of root: SlotRoot) throws(SlotRoot.Failure) -> any PayloadLanding {
        let directory = try root.openSlot(slot)
        let file = openat(directory, Self.partialName, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o700)
        guard file >= 0 else {
            let failure = errno
            close(directory)
            throw SlotRoot.Failure(operation: "create", name: Self.partialName, errno: failure)
        }
        return Landing(
            system: system, slot: directory, file: file, staged: root.path + "/slots/" + slot + "/" + Self.partialName)
    }

    /// One update, written to ``partialName`` in the slot until it is published as the slot's binary.
    struct Landing: PayloadLanding {
        let system: System
        /// The slot, open.
        let slot: Int32
        /// The staged file, open for writing.
        let file: Int32
        /// The staged file's path, which the self-test runs.
        let staged: String

        func write(_ bytes: UnsafeRawBufferPointer) throws(SlotRoot.Failure) {
            var offset = 0
            while offset < bytes.count {
                let count = system.write(file, UnsafeRawBufferPointer(rebasing: bytes[offset...]))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw SlotRoot.Failure(operation: "write", name: partialName, errno: count < 0 ? errno : EIO)
                }
                offset += count
            }
        }

        /// Flushes the staged binary, makes it executable, runs its self-test, and renames it over the slot's
        /// binary.
        func publish() throws(PayloadRefusal) {
            var file = self.file
            defer {
                if file >= 0 { close(file) }
                close(slot)
            }
            func refuse(_ detail: String, errno: Int32 = 0, rejects: Bool = false) -> PayloadRefusal {
                unlinkat(slot, partialName, 0)
                return PayloadRefusal(.updateInstallFailed, detail, errno: errno, rejectsPayload: rejects)
            }
            guard fsync(file) == 0 else { throw refuse("fsync", errno: errno) }
            guard fchmod(file, 0o755) == 0 else { throw refuse("chmod", errno: errno) }
            // Closed first: a file open for writing cannot be executed (ETXTBSY).
            close(file)
            file = -1
            let outcome = system.selfTest(staged)
            guard outcome == .passed else { throw refuse("self-test: \(outcome)", rejects: true) }
            guard renameat(slot, partialName, slot, InstallLayout.binaryName) == 0, fsync(slot) == 0 else {
                throw refuse("rename into the slot", errno: errno)
            }
        }

        func discard() {
            close(file)
            unlinkat(slot, partialName, 0)
            close(slot)
        }

        private var partialName: String { ExecutableLander.partialName }
    }
}

/// write(2) of `buffer` to `file`.
private func posixWrite(_ file: Int32, _ buffer: UnsafeRawBufferPointer) -> Int {
    write(file, buffer.baseAddress, buffer.count)
}
#endif
