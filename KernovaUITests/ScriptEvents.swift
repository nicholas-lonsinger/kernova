import Cocoa
import CoreServices
import KernovaTestSupport
import Testing

@testable import KernovaUI

/// Apple events in the shape AppleScript sends them, for a test to dispatch
/// to the test host as a script would.
///
/// A command a test builds by hand evaluates nothing the way a script's does:
/// Cocoa builds every command and specifier from the event it dispatches, and
/// splits a `set` or `delete`'s receivers as it does. Only a dispatched event
/// shows what a script sees.
enum ScriptEvent {
    /// The four-character Apple event code `text` spells.
    static func code(_ text: String) -> FourCharCode {
        FourCharCode(scriptingCode: text)
    }

    // MARK: - References

    /// The application, which every reference is rooted in.
    static var application: NSAppleEventDescriptor { .null() }

    /// The element a `whose` test is testing — `it`.
    static var examined: NSAppleEventDescriptor { NSAppleEventDescriptor(descriptorType: code("exmn"), data: nil)! }

    /// `<class> "<name>" of <container>`.
    static func element(
        _ elementClass: String, named name: String, of container: NSAppleEventDescriptor = application
    ) -> NSAppleEventDescriptor {
        reference(elementClass, form: "name", NSAppleEventDescriptor(string: name), of: container)
    }

    /// `<class> id "<id>" of <container>`.
    static func element(
        _ elementClass: String, id: String, of container: NSAppleEventDescriptor = application
    ) -> NSAppleEventDescriptor {
        reference(elementClass, form: "ID  ", NSAppleEventDescriptor(string: id), of: container)
    }

    /// `<class> <index> of <container>`, counting from 1.
    static func element(
        _ elementClass: String, at index: Int32, of container: NSAppleEventDescriptor = application
    ) -> NSAppleEventDescriptor {
        reference(elementClass, form: "indx", NSAppleEventDescriptor(int32: index), of: container)
    }

    /// `every <class> of <container>`.
    static func every(
        _ elementClass: String, of container: NSAppleEventDescriptor = application
    ) -> NSAppleEventDescriptor {
        var all = code("all ")
        let ordinal = NSAppleEventDescriptor(
            descriptorType: code("abso"), bytes: &all, length: MemoryLayout<FourCharCode>.size)!
        return reference(elementClass, form: "indx", ordinal, of: container)
    }

    /// `every <class> of <container> whose <test>`.
    static func every(
        _ elementClass: String, of container: NSAppleEventDescriptor = application,
        whose test: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        reference(elementClass, form: "test", test, of: container)
    }

    /// `<property> of <container>`.
    static func property(_ property: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        reference("prop", form: "prop", NSAppleEventDescriptor(typeCode: code(property)), of: container)
    }

    /// `end of <reference>`, the insertion location `make … at` takes.
    static func end(of reference: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let location = record(as: "insl")
        location.setDescriptor(reference, forKeyword: code("kobj"))
        location.setDescriptor(NSAppleEventDescriptor(enumCode: code("end ")), forKeyword: code("kpos"))
        return location
    }

    /// `<lhs> is <rhs>`, as a `whose` test.
    static func equals(_ lhs: NSAppleEventDescriptor, _ rhs: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let comparison = record(as: "cmpd")
        comparison.setDescriptor(NSAppleEventDescriptor(enumCode: code("=   ")), forKeyword: code("relo"))
        comparison.setDescriptor(lhs, forKeyword: code("obj1"))
        comparison.setDescriptor(rhs, forKeyword: code("obj2"))
        return comparison
    }

    private static func reference(
        _ elementClass: String, form: String, _ selector: NSAppleEventDescriptor,
        of container: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        let reference = record(as: "obj ")
        reference.setDescriptor(NSAppleEventDescriptor(typeCode: code(elementClass)), forKeyword: code("want"))
        reference.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        reference.setDescriptor(selector, forKeyword: code("seld"))
        reference.setDescriptor(container, forKeyword: code("from"))
        return reference
    }

    private static func record(as type: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.record().coerce(toDescriptorType: code(type))!
    }

    // MARK: - Events

    /// `get <reference>`.
    static func get(_ reference: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        event("core", "getd", reference)
    }

    /// `set <reference> to <value>`.
    static func set(_ reference: NSAppleEventDescriptor, to value: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let set = event("core", "setd", reference)
        set.setParam(value, forKeyword: code("data"))
        return set
    }

    /// `make new <class> [at <location>] [with properties <properties>]`.
    static func make(
        new elementClass: String, at location: NSAppleEventDescriptor? = nil,
        properties: [String: NSAppleEventDescriptor] = [:]
    ) -> NSAppleEventDescriptor {
        let make = event("core", "crel", nil)
        make.setParam(NSAppleEventDescriptor(typeCode: code(elementClass)), forKeyword: code("kocl"))
        if let location { make.setParam(location, forKeyword: code("insh")) }
        if !properties.isEmpty {
            let record = NSAppleEventDescriptor.record()
            for (property, value) in properties { record.setDescriptor(value, forKeyword: code(property)) }
            make.setParam(record, forKeyword: code("prdt"))
        }
        return make
    }

    /// `event` as a `tell <subject>` block sends it: the subject travels as an
    /// attribute, which Cocoa promotes to the receivers of a command naming
    /// none.
    static func told(_ event: NSAppleEventDescriptor, to subject: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        event.setAttribute(subject, forKeyword: code("subj"))
        return event
    }

    /// `delete <reference> [with confirmation] [with immediate deletion]`.
    static func delete(
        _ reference: NSAppleEventDescriptor, confirmation: Bool = false, immediateDeletion: Bool = false
    ) -> NSAppleEventDescriptor {
        let delete = confirming(event("core", "delo", reference), confirmation)
        if immediateDeletion { delete.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: code("KpIm")) }
        return delete
    }

    /// `duplicate <reference> [as <outcome>]`, the outcome named by its
    /// enumerator's code.
    static func duplicate(_ reference: NSAppleEventDescriptor, as outcome: String? = nil) -> NSAppleEventDescriptor {
        let duplicate = event("core", "clon", reference)
        if let outcome { duplicate.setParam(NSAppleEventDescriptor(enumCode: code(outcome)), forKeyword: code("KpCo")) }
        return duplicate
    }

    /// `change <reference> to <value> [with confirmation]`.
    static func change(
        _ reference: NSAppleEventDescriptor, to value: NSAppleEventDescriptor, confirmation: Bool = false
    ) -> NSAppleEventDescriptor {
        let change = verb("Chng", reference, confirmation: confirmation)
        change.setParam(value, forKeyword: code("data"))
        return change
    }

    /// One of Kernova's own verbs, `<verb> <reference> [with confirmation]`.
    static func verb(
        _ verb: String, _ reference: NSAppleEventDescriptor, confirmation: Bool = false
    ) -> NSAppleEventDescriptor {
        confirming(event("Krnv", verb, reference), confirmation)
    }

    /// `event`, carrying `with confirmation` when `confirmation` says so.
    private static func confirming(_ event: NSAppleEventDescriptor, _ confirmation: Bool) -> NSAppleEventDescriptor {
        if confirmation { event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: code("Kpcf")) }
        return event
    }

    private static func event(
        _ eventClass: String, _ eventID: String, _ direct: NSAppleEventDescriptor?
    ) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: code(eventClass), eventID: code(eventID), targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let direct { event.setParam(direct, forKeyword: keyDirectObject) }
        return event
    }
}

/// What a script reads back from one event: the result, or the error it
/// stopped with.
struct ScriptReply {
    /// The result, as Cocoa answered it — a descriptor, or for a command
    /// answered later, what the gateway resumed it with.
    let result: Any?
    let errorNumber: Int
    let errorString: String?
    let offendingObject: NSAppleEventDescriptor?

    init(_ reply: NSAppleEventDescriptor) {
        result = reply.paramDescriptor(forKeyword: keyDirectObject)
        errorNumber = Int(reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0)
        errorString = reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue
        offendingObject = reply.paramDescriptor(forKeyword: ScriptEvent.code("erob"))
    }

    init(_ command: NSScriptCommand, resumedWith result: Any?) {
        self.result = result
        errorNumber = command.scriptErrorNumber
        errorString = command.scriptErrorString
        offendingObject = command.scriptErrorOffendingObjectDescriptor
    }

    /// The result as a descriptor, which is what the script reads.
    var descriptor: NSAppleEventDescriptor? { Self.descriptor(of: result) }

    /// `value` — a descriptor, or what a command is resumed with — as the
    /// descriptor the script reads.
    private static func descriptor(of value: Any?) -> NSAppleEventDescriptor? {
        switch value {
        case let descriptor as NSAppleEventDescriptor: return descriptor
        case let specifier as NSScriptObjectSpecifier: return specifier.descriptor
        case let text as String: return NSAppleEventDescriptor(string: text)
        case let items as [Any]:
            let list = NSAppleEventDescriptor.list()
            for item in items {
                guard let descriptor = descriptor(of: item) else { return nil }
                list.insert(descriptor, at: list.numberOfItems + 1)
            }
            return list
        default: return nil
        }
    }

    /// The result's items, a list's in order or a lone value's alone.
    var items: [NSAppleEventDescriptor] { descriptor?.items ?? [] }
}

/// Dispatches Apple events to the test host the way a script sends them,
/// answered by one gateway, and reads back what the script would.
///
/// Every command it dispatches is Cocoa's own, suspended and resumed by Cocoa;
/// this only watches the gateway suspend and resume them.
@MainActor
final class ScriptHost {
    /// How many commands the gateway suspended.
    private(set) var suspensions = 0
    private var resumptions: [ScriptReply] = []
    private let resumed = AsyncGate()

    /// Cocoa's own runtime, watched.
    var runtime: VMScriptCommandRuntime {
        let cocoa = VMScriptCommandRuntime.cocoa
        return VMScriptCommandRuntime(
            current: cocoa.current,
            suspend: { command in
                self.suspensions += 1
                cocoa.suspend(command)
            },
            resume: { command, result in
                self.resumptions.append(ScriptReply(command, resumedWith: result))
                cocoa.resume(command, result)
                self.resumed.notify()
            })
    }

    /// Dispatches `event`, answered by `gateway`, without waiting for a
    /// command it suspends.
    ///
    /// - Returns: The reply, or `nil` when the gateway suspended the command —
    ///   Cocoa answers a suspended event's in-process sender at once with a
    ///   timeout.
    func dispatch(_ event: NSAppleEventDescriptor, to gateway: VMScriptingGateway) throws -> ScriptReply? {
        try TestScriptingRoot.serving(gateway) {
            do {
                return ScriptReply(
                    try event.sendEvent(options: [.waitForReply], timeout: TimeInterval(kAEDefaultTimeout)))
            } catch let error as NSError where error.code == Int(errAETimeout) {
                return nil
            }
        }
    }

    /// What the `index`th command the gateway resumed was answered with, once
    /// it is.
    func answer(_ index: Int = 0) async throws -> ScriptReply {
        try await resumed.wait { self.resumptions.count > index }
        return resumptions[index]
    }

    /// Dispatches `event`, answered by `gateway`, and returns what the script
    /// reads back — the reply, or what the gateway answered a command it
    /// suspended with.
    func send(_ event: NSAppleEventDescriptor, to gateway: VMScriptingGateway) async throws -> ScriptReply {
        let answered = resumptions.count
        if let reply = try dispatch(event, to: gateway) { return reply }
        return try await answer(answered)
    }
}

/// A command a test stands in for the one Cocoa is executing, for a gateway
/// call the test makes outside any Apple event.
@MainActor
final class ScriptCommandStandIn {
    var command: NSScriptCommand?

    /// Cocoa's own runtime, reporting ``command`` as the one executing.
    var runtime: VMScriptCommandRuntime {
        var runtime = VMScriptCommandRuntime.cocoa
        runtime.current = { self.command }
        return runtime
    }
}

extension NSAppleEventDescriptor {
    /// A list's items in order, or a lone value alone.
    var items: [NSAppleEventDescriptor] {
        guard descriptorType == typeAEList else { return [self] }
        return stride(from: 1, through: numberOfItems, by: 1).compactMap { atIndex($0) }
    }
}
