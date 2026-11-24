import Cocoa
import CoreServices
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The dictionary's `setting`: what a script reads of a VM's settings, which
/// setting `set value of` and `change` write, and with what consent.
///
/// A script's own events are dispatched to the test host (``ScriptHost``) and
/// answered by the gateway under test.
@Suite("VM setting scripting", .caseScoped)
@MainActor
struct VMSettingScriptingTests {
    /// A gateway whose library read has landed.
    private func makeGateway(_ wired: WiredCommandCore, host: ScriptHost) async -> VMScriptingGateway {
        let readiness = LibraryReadiness(awaitReady: {})
        await readiness.ready()
        return VMScriptingGateway(
            commands: wired.core, readiness: readiness, prepareToSurface: {}, runtime: host.runtime)
    }

    /// `virtual machine "<name>"`.
    private static func vm(named name: String) -> NSAppleEventDescriptor {
        ScriptEvent.element("KvVM", named: name)
    }

    /// `setting "<key>" of virtual machine "<vm>"`.
    fileprivate static func setting(_ key: String, of vm: String) -> NSAppleEventDescriptor {
        ScriptEvent.element("KvCf", named: key, of: Self.vm(named: vm))
    }

    /// `{<items>}`.
    fileprivate static func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
        return list
    }

    /// `{"<text>", …}`.
    fileprivate static func texts(_ texts: [String]) -> NSAppleEventDescriptor {
        list(texts.map(NSAppleEventDescriptor.init(string:)))
    }

    // MARK: - Reads

    /// One `setting` as `get properties` answers it.
    private struct SettingRow: Equatable {
        let name: String?
        let value: String?
        let summary: String?

        init(_ record: NSAppleEventDescriptor) {
            name = record.forKeyword(ScriptEvent.code("pnam"))?.stringValue
            value = record.forKeyword(ScriptEvent.code("valL"))?.stringValue
            summary = record.forKeyword(ScriptEvent.code("KvSy"))?.stringValue
        }
    }

    @Test(
        "A VM's settings are the keys its guest has, each with its value and its key's summary, and one it lacks is refused by name"
    )
    func settingsReadTheKeysTheGuestHas() async throws {
        let wired = WiredCommandCore()
        wired.register(name: "Mac", guestOS: .macOS) {
            $0.cpuCount = 6
            $0.memorySizeInGB = .gibibytes(8)
        }
        wired.register(name: "Tux", guestOS: .linux)
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)

        let mac = try await host.send(
            ScriptEvent.get(ScriptEvent.property("pALL", of: ScriptEvent.every("KvCf", of: Self.vm(named: "Mac")))),
            to: gateway)
        let tux = try await host.send(
            ScriptEvent.get(ScriptEvent.property("pnam", of: ScriptEvent.every("KvCf", of: Self.vm(named: "Tux")))),
            to: gateway)
        let lacked = try await host.send(
            ScriptEvent.get(ScriptEvent.property("valL", of: Self.setting("display.hidpi", of: "Tux"))), to: gateway)

        #expect(mac.errorNumber == 0)
        let rows = mac.items.map(SettingRow.init)
        let byName = Dictionary(rows.map { ($0.name ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        #expect(rows.count == byName.count)
        #expect(byName["cpus"]?.value == "6")
        #expect(byName["memory"]?.value == "8")
        #expect(byName["cpus"]?.summary == VMConfigurationKeyRegistry.cpus.summary)
        #expect(byName["input.devices"] != nil)
        #expect(byName["display.hidpi"] != nil)
        let tuxNames = tux.items.compactMap(\.stringValue)
        #expect(tuxNames.contains("cpus"))
        #expect(!tuxNames.contains("input.devices"))
        #expect(!tuxNames.contains("display.hidpi"))
        #expect(lacked.errorNumber == Int(errAEEventFailed))
        #expect(lacked.errorString?.contains("display.hidpi") == true)
    }

    // MARK: - Writes

    /// The ways a script writes one VM's setting, and another's beside it.
    enum WriteForm: CaseIterable, Sendable {
        /// `set value of setting "cpus" of virtual machine "Beta" to "3"`
        case set
        /// `change setting "cpus" of virtual machine "Beta" to "3"`
        case change
        /// `change {setting "cpus" of virtual machine "Beta", setting "memory"
        /// of virtual machine "Alpha", setting "memory" of virtual machine
        /// "Beta"} to {"3", "5", "6"}`
        case changeList

        /// The event, and what it answers.
        @MainActor
        func event() -> (event: NSAppleEventDescriptor, answers: [String]?) {
            let cpus = VMSettingScriptingTests.setting("cpus", of: "Beta")
            return switch self {
            case .set:
                (ScriptEvent.set(ScriptEvent.property("valL", of: cpus), to: NSAppleEventDescriptor(string: "3")), nil)
            case .change: (ScriptEvent.change(cpus, to: NSAppleEventDescriptor(string: "3")), ["3"])
            case .changeList:
                (
                    ScriptEvent.change(
                        VMSettingScriptingTests.list([
                            cpus, VMSettingScriptingTests.setting("memory", of: "Alpha"),
                            VMSettingScriptingTests.setting("memory", of: "Beta"),
                        ]),
                        to: VMSettingScriptingTests.texts(["3", "5", "6"])),
                    ["3", "5", "6"]
                )
            }
        }
    }

    @Test(
        "A write lands on the setting it names, of the VM it names, and change answers what each holds",
        arguments: WriteForm.allCases)
    func aWriteLandsOnTheSettingItNames(form: WriteForm) async throws {
        let wired = WiredCommandCore()
        let alpha = wired.register(name: "Alpha") {
            $0.cpuCount = 2
            $0.memorySizeInGB = .gibibytes(4)
        }
        let beta = wired.register(name: "Beta") {
            $0.cpuCount = 2
            $0.memorySizeInGB = .gibibytes(4)
        }
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)
        let (event, answers) = form.event()

        let reply = try await host.send(event, to: gateway)

        #expect(reply.errorNumber == 0, "\(reply.errorString ?? "")")
        #expect(beta.configuration.cpuCount == 3)
        #expect(alpha.configuration.cpuCount == 2)
        #expect(alpha.configuration.memorySizeInGB == .gibibytes(form == .changeList ? 5 : 4))
        #expect(beta.configuration.memorySizeInGB == .gibibytes(form == .changeList ? 6 : 4))
        if let answers {
            #expect(reply.items.map(\.stringValue) == answers)
        }
    }

    @Test(
        "A change that asks for consent is refused without with confirmation, naming how to give it, and lands with it")
    func consentComesFromChangeWithConfirmation() async throws {
        let wired = WiredCommandCore()
        let clean = VMSnapshot(name: "Clean", kind: .cold, macAddress: nil)
        let alpha = wired.register(name: "Alpha", snapshots: [clean])
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)
        let ephemeral = Self.setting("ephemeral", of: "Alpha")
        let on = NSAppleEventDescriptor(string: "true")
        let refusal = CommandError.confirmationRequired(
            VMCommandCore.ephemeralBaselinePrompt(clean, on: alpha, turningOn: true))

        let set = try await host.send(ScriptEvent.set(ScriptEvent.property("valL", of: ephemeral), to: on), to: gateway)
        let unconfirmed = try await host.send(ScriptEvent.change(ephemeral, to: on), to: gateway)

        #expect(set.errorNumber == Int(errAEEventFailed))
        #expect(set.errorString == refusal.appleEventErrorString(consenting: VMScriptingGateway.changeGivesConsent))
        #expect(unconfirmed.errorNumber == Int(errAEEventFailed))
        #expect(unconfirmed.errorString == refusal.appleEventErrorString(consenting: CommandError.withConfirmation))
        #expect(!alpha.hostState.ephemeralModeEnabled)

        let confirmed = try await host.send(ScriptEvent.change(ephemeral, to: on, confirmation: true), to: gateway)

        #expect(confirmed.errorNumber == 0, "\(confirmed.errorString ?? "")")
        #expect(confirmed.descriptor?.stringValue == "true")
        #expect(alpha.hostState.ephemeralModeEnabled)
        #expect(alpha.hostState.ephemeralBaselineSnapshotID == clean.id)
    }

    @Test("A change of several settings of one VM writes all of them or none")
    func aChangeOfOneVMIsAllOrNone() async throws {
        let wired = WiredCommandCore()
        let alpha = wired.register(name: "Alpha") { $0.cpuCount = 2 }
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)

        let reply = try await host.send(
            ScriptEvent.change(
                Self.list([Self.setting("cpus", of: "Alpha"), Self.setting("memory", of: "Alpha")]),
                to: Self.texts(["3", "a lot"])),
            to: gateway)

        #expect(reply.errorNumber == Int(errAETypeError))
        #expect(reply.errorString?.contains("memory") == true)
        #expect(alpha.configuration.cpuCount == 2)
    }
}
