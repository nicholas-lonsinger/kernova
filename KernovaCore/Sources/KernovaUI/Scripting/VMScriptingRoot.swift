import Cocoa
import KernovaCore

/// The application's delegate as the scripting root: `NSApplication` is the
/// root of the dictionary, which gives it `virtual machines` and `networks`
/// elements — keys it forwards here, and every one of which reaches
/// ``scriptingGateway``.
///
/// Every command Cocoa builds from a script's event reaches the gateway
/// through here: Cocoa hands a command nothing else to work with.
@MainActor
package class VMScriptingRoot: NSObject, NSApplicationDelegate {
    /// The Apple event front door, `nil` until the app has one — which
    /// answers every element empty and every verb as not ready.
    var scriptingGateway: VMScriptingGateway? { nil }

    package func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        Self.scriptingKeys.contains(key)
    }

    /// The literal KVC key the dictionary's `virtual machine` element is
    /// declared with, which is also the key Cocoa asks this delegate for.
    nonisolated static let virtualMachinesKey = "virtualMachines"

    /// The literal KVC key the dictionary's `network` element is declared with.
    nonisolated static let networksKey = "networks"

    /// Every element key the application's dictionary entry declares.
    package nonisolated static let scriptingKeys: Set<String> = [virtualMachinesKey, networksKey]

    /// Every VM in the library, as the dictionary's `virtual machine` elements.
    ///
    /// Synchronous because KVC is: Cocoa evaluates a specifier inside the Apple
    /// event's own callout. A read the gateway cannot answer yet suspends the
    /// command Cocoa is evaluating for, and the gateway answers it later.
    @objc var virtualMachines: [VMScriptObject] {
        scriptingGateway?.virtualMachines() ?? []
    }

    /// The named-element accessor Cocoa resolves `virtual machine "…"` through.
    ///
    /// Cocoa's own answer, without this, is the first VM whose name matches
    /// case-insensitively — which for two VMs sharing a display name is
    /// whichever the library lists first, described to the script as though it
    /// were the one asked for. ``VMScriptingGateway/virtualMachine(named:)``
    /// resolves the name through the core instead, and a name the core refuses
    /// — as ambiguous, or as unknown — reads back in the core's words.
    @objc(valueInVirtualMachinesWithName:)
    func valueInVirtualMachines(withName name: String) -> VMScriptObject? {
        scriptingGateway?.virtualMachine(named: name)
    }

    /// Every named network, as the dictionary's `network` elements, read as
    /// ``virtualMachines`` is.
    @objc var networks: [VMNetworkScriptObject] {
        scriptingGateway?.networks() ?? []
    }

    /// What `make new …` creates as an element of the application: Cocoa asks
    /// `NSApplication`, which forwards a key this delegate handles.
    package nonisolated override func newScriptingObject(
        of objectClass: AnyClass, forValueForKey key: String, withContentsValue contentsValue: Any?,
        properties: [String: Any]
    ) -> Any? {
        // Cocoa has coerced each property to the type the dictionary declares.
        let name = properties["name"] as? String
        let kind = properties["kind"] as? NSNumber
        return MainActor.assumeIsolated { () -> VMNetworkScriptObject? in
            guard let gateway = scriptingGateway else {
                NSScriptCommand.current()?.refuse(Int(errAEEventFailed), VMScriptCommand.notReady)
                return nil
            }
            return gateway.makeElement(forKey: key, name: name, kind: kind)
        }
    }

    /// Where Cocoa inserts what ``newScriptingObject(of:forValueForKey:withContentsValue:properties:)``
    /// answered, and a `move` re-inserts what it removed: the core listed the
    /// network when it was made, so there is nothing to insert.
    @objc(insertInNetworks:)
    func insertInNetworks(_ network: Any) {}

    /// The positional spelling of ``insertInNetworks(_:)``, which `make … at`
    /// and `move` reach: the networks are ordered by name, so the position
    /// names nothing.
    @objc(insertInNetworks:atIndex:)
    func insertInNetworks(_ network: Any, at index: Int) {}

    /// Where Cocoa removes a network for a `delete` — and for a `move`, which
    /// ``VMScriptingGateway/removeNetwork(at:)`` refuses.
    @objc(removeFromNetworksAtIndex:)
    func removeFromNetworks(at index: Int) {
        scriptingGateway?.removeNetwork(at: index)
    }
}
