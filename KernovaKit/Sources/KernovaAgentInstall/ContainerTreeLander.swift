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

import KernovaContainer
import KernovaFileTree
import KernovaTreeTransfer
import KernovaWire

/// The lander of `PAYLOAD_FORMAT_CONTAINER_TREE`: a container in the update profile (``UpdatePayloadPacker``),
/// landed by `TreeReceiver` into the slot and published there under ``itemName`` — the macOS agent's app
/// bundle. It stages beside its destination, so the bytes are written once, on the slot's volume; what the
/// slot held under that name stays until the landing publishes, and comes back when it is refused.
public struct ContainerTreeLander: PayloadLander {
    /// The calls the lander makes into the system, replaced in tests.
    public struct System: Sendable {
        /// Runs the executable at a path through its `self-test`.
        public var selfTest: @Sendable (String) -> SelfTest.Outcome
        /// Why the guest OS would not launch the item at a path in place of the running agent, or nil when it
        /// would: the OS's own check, which the platform's agent supplies.
        public var launchRefusal: @Sendable (String) -> PayloadRefusal?

        /// Runs `SelfTest.run(_:)`, and `launchRefusal` for the launch check.
        public init(
            selfTest: @escaping @Sendable (String) -> SelfTest.Outcome = { SelfTest.run($0) },
            launchRefusal: @escaping @Sendable (String) -> PayloadRefusal?
        ) {
            self.selfTest = selfTest
            self.launchRefusal = launchRefusal
        }
    }

    /// The name the item lands under in its slot.
    public let itemName: String
    /// The executable in the item that an update's self-test runs, relative to the item.
    public let selfTestExecutable: String
    let system: System

    /// The lander of items published as `itemName`, an update's checked by `system`'s launch check and then by
    /// running `selfTestExecutable` in it.
    public init(itemName: String, selfTestExecutable: String, system: System) {
        self.itemName = itemName
        self.selfTestExecutable = selfTestExecutable
        self.system = system
    }

    /// `PAYLOAD_FORMAT_CONTAINER_TREE`.
    public var format: PayloadFormat { .containerTree }

    /// What a landing accepts: the update profile's folder, plain chunks, no decmpfs storage.
    static let acceptance = ContainerAcceptance(
        storage: .folder, byteCeiling: .max, decmpfsTypes: [], acceptsLZ4: false)

    /// Lands the install's payload as `name` in `slot`, replacing what the slot holds there. The tree belongs
    /// to the installer: no install scope that lands this format hands its root to another account.
    public func install(
        _ payload: InstallPayloadReader, as name: String, in slot: borrowing InstallDirectory<Installer.Failure>
    ) throws(Installer.Failure) {
        let path = slot.path
        guard slot.owner == nil else {
            throw .system(operation: "hand to the account", path: path + "/" + name, errno: ENOTSUP)
        }
        let landing = try Self.landing(name, in: slot.descriptor, path: path) {
            operation, errno throws(Installer.Failure) in
            Installer.Failure.system(operation: operation, path: path, errno: errno)
        }
        try payload.read { piece throws(Installer.Failure) in
            do throws(TreeWriteFailure) {
                try landing.receive(Data(piece))
            } catch {
                throw .system(operation: "land \(error)", path: path + "/" + name, errno: error.errno)
            }
        }
        do throws(PayloadRefusal) {
            try landing.publish(check: nil)
        } catch {
            throw .system(operation: error.detail, path: path + "/" + name, errno: error.errno)
        }
    }

    /// Begins landing an update in `slot` of `root`, staged beside the slot's item.
    public func beginUpdate(in slot: String, of root: SlotRoot) throws(SlotRoot.Failure) -> any PayloadLanding {
        let directory = try root.openSlot(slot)
        let path = directory.path
        let landing = try Self.landing(itemName, in: directory.descriptor, path: path) {
            operation, errno throws(SlotRoot.Failure) in
            SlotRoot.Failure(operation: operation, path: path, errno: errno)
        }
        let item = path + "/" + itemName
        let executable = item + "/" + selfTestExecutable
        return Update(landing: landing, item: item) { [system] in
            if let refusal = system.launchRefusal(item) { return refusal }
            let outcome = system.selfTest(executable)
            return outcome == .passed ? nil : PayloadRefusal(.updateInstallFailed, "self-test: \(outcome)")
        }
    }

    /// A landing of the item `name` in the open `directory` at `path`, the receiver given a descriptor of its own.
    private static func landing<Failure: Error>(
        _ name: String, in directory: Int32, path: String, _ failure: (String, Int32) throws(Failure) -> Failure
    ) throws(Failure) -> TreeLanding {
        let destination = dup(directory)
        guard destination >= 0 else { throw try failure("dup", errno) }
        let held = dup(directory)
        guard held >= 0 else {
            let code = errno
            close(destination)
            throw try failure("dup", code)
        }
        let receiver = TreeReceiver(
            name: .exactly(Array(name.utf8)), accepting: acceptance, decodingWorkers: 0,
            fileSystem: POSIXTreeFileSystem(),
            destination: destination,
            destinationPathByteCount: path.utf8.count)
        return TreeLanding(receiver: receiver, name: name, directory: held)
    }

    /// One update payload, landing in its slot. ``SlotUpdateInstaller`` calls it from its own queue alone,
    /// one call at a time, which is what makes its unsynchronized state safe to share.
    final class Update: PayloadLanding, @unchecked Sendable {
        private let landing: TreeLanding
        /// The item's path, for messages.
        private let item: String
        private let check: @Sendable () -> PayloadRefusal?

        init(landing: TreeLanding, item: String, check: @escaping @Sendable () -> PayloadRefusal?) {
            self.landing = landing
            self.item = item
            self.check = check
        }

        func write(_ bytes: UnsafeRawBufferPointer) throws(SlotRoot.Failure) {
            do throws(TreeWriteFailure) {
                try landing.receive(Data(bytes))
            } catch {
                throw SlotRoot.Failure(
                    operation: "land", path: item, errno: error.errno, detail: String(describing: error))
            }
        }

        /// Publishes the landed tree as the slot's item, once the guest OS would launch it and its self-test
        /// passes: a container that does not end whole, an item the OS would not launch, or one that does not run
        /// is refused.
        func publish() throws(PayloadRefusal) {
            try landing.publish(check: check)
        }

        func discard() {
            landing.discard()
        }
    }
}

/// A `TreeReceiver` landing in a directory, and the publish that replaces what the directory holds under the
/// item's name: moved aside first, removed once the new item is in place, and put back on any refusal, so
/// nothing the landing did not create is lost unless the new item publishes.
final class TreeLanding {
    /// The receiver until the landing publishes or is discarded; releasing it removes what it staged.
    private var receiver: TreeReceiver<POSIXTreeFileSystem>?
    /// The item's name, which the receiver publishes it under.
    private let name: String
    /// The destination, open, for the swap around the publish.
    private let directory: Int32
    private let fileSystem = POSIXTreeFileSystem()

    init(receiver: TreeReceiver<POSIXTreeFileSystem>, name: String, directory: Int32) {
        self.receiver = receiver
        self.name = name
        self.directory = directory
    }

    deinit {
        receiver = nil
        close(directory)
    }

    /// Takes the payload's next bytes.
    func receive(_ bytes: Data) throws(TreeWriteFailure) {
        guard let receiver else { preconditionFailure("bytes after the landing ended") }
        try receiver.receive(bytes)
    }

    /// Publishes the landed item as its name, then runs `check`, which answers why the item is refused, or nil.
    func publish(check: (() -> PayloadRefusal?)?) throws(PayloadRefusal) {
        guard let receiver else { preconditionFailure("a publish after the landing ended") }
        self.receiver = nil
        let bytes = Array(name.utf8)
        let aside = Array(".\(name).kernova-old".utf8)
        try removeIfPresent(aside)
        let movedAside: Bool
        do {
            try fileSystem.rename(bytes, in: directory, to: aside, in: directory)
            movedAside = true
        } catch  where error.code == ENOENT {
            movedAside = false
        } catch {
            throw PayloadRefusal(
                .updateInstallFailed, "move the old item aside", errno: error.code, rejectsPayload: false)
        }
        func restore() {
            if movedAside { try? fileSystem.rename(aside, in: directory, to: bytes, in: directory) }
        }
        do throws(TreeWriteFailure) {
            try receiver.finish()
            _ = try receiver.publish()
        } catch {
            restore()
            let rejects = if case .container = error.reason { true } else { false }
            throw PayloadRefusal(.updateInstallFailed, "land: \(error)", errno: error.errno, rejectsPayload: rejects)
        }
        if let refusal = check?() {
            try? TreeRemoval.remove(bytes, in: directory, on: fileSystem)
            restore()
            throw refusal
        }
        if movedAside { try? TreeRemoval.remove(aside, in: directory, on: fileSystem) }
        fsync(directory)
    }

    /// Removes what the receiver staged, unpublished.
    func discard() {
        receiver = nil
    }

    private func removeIfPresent(_ name: [UInt8]) throws(PayloadRefusal) {
        do { try TreeRemoval.remove(name, in: directory, on: fileSystem) } catch {
            guard (error as? TreeFileSystemError)?.code == ENOENT else {
                throw PayloadRefusal(
                    .updateInstallFailed, "remove a stale old item: \(error)", rejectsPayload: false)
            }
        }
    }
}

extension TreeWriteFailure {
    /// The failed call's errno; 0 when no call failed, as for a malformed container.
    var errno: Int32 {
        if case .system(let error) = reason { return error.code }
        return 0
    }
}
#endif
