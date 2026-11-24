import Cocoa
import KernovaCommandModel
import KernovaCore
import KernovaLogging

/// One setting, as a verb a script runs names it: the VM it belongs to, and
/// its key.
struct VMSettingAddress: Hashable, Sendable {
    let vm: UUID
    let key: String
}

/// One of a VM's settings, as the scripting dictionary's `setting`: a key of
/// the keyspace and its value as ``VMCommandCore/configuration(_:keys:)``
/// reads it, and the key's summary.
///
/// A copy of one read, like ``VMScriptObject``: the VM reads its settings
/// afresh on every specifier evaluation. Setting `value` is the settings
/// write, run by ``VMScriptingGateway/setSetting(_:to:)``.
@MainActor
@objc(VMSettingScriptObject)
package final class VMSettingScriptObject: NSObject {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMSettingScriptObject")

    /// The key and the value it held when read.
    private let entry: ConfigurationEntry
    /// Which setting it is.
    let address: VMSettingAddress
    /// Where a write runs.
    private weak var gateway: VMScriptingGateway?

    /// What the key holds and the values it takes, in one line.
    @objc let summary: String

    init(_ entry: ConfigurationEntry, summary: String, of vm: UUID, gateway: VMScriptingGateway) {
        self.entry = entry
        self.summary = summary
        address = VMSettingAddress(vm: vm, key: entry.key)
        self.gateway = gateway
    }

    // MARK: - Properties

    @objc var name: String { entry.key }

    @objc var value: String {
        get { entry.value }
        set { gateway?.setSetting(address, to: newValue) }
    }

    // MARK: - Specifier

    /// How a script names this setting back — `setting "<key>"` of
    /// `virtual machine id "…"`: a key names one setting of a VM.
    package nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        Self.specifier(for: address)
    }

    /// `setting "<key>"` of `virtual machine id "…"`, for the setting
    /// `address` names.
    nonisolated static func specifier(for address: VMSettingAddress) -> NSScriptObjectSpecifier? {
        guard let virtualMachine = NSScriptClassDescription(for: VMScriptObject.self) else {
            Self.logger.log(.fault, "VMScriptObject has no scripting class description")
            assertionFailure("VMScriptObject has no scripting class description")
            return nil
        }
        return NSNameSpecifier(
            containerClassDescription: virtualMachine,
            containerSpecifier: VMScriptObject.specifier(for: address.vm),
            key: VMScriptObject.settingsKey,
            name: address.key)
    }
}
