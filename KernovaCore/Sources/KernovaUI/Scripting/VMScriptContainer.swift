import Cocoa
import KernovaLogging

/// A dictionary object that holds elements, which evaluates a range of them
/// bounded by a name, and the element before or after a named one, itself:
/// each name resolves by the container's `valueIn<Key>WithName:` accessor —
/// the rule the name alone resolves by — and one the accessor refuses names
/// nothing. Every other specifier, a name alone included, is Cocoa's.
///
/// "Container classes that want to evaluate certain object specifiers on their
/// own should implement the `indicesOfObjectsByEvaluatingObjectSpecifier:`
/// method", as Apple's Sketch sample does to "directly handle some range and
/// relative specifiers" ([Object Specifiers](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ScriptableCocoaApplications/SApps_object_specifiers/SAppsObjectSpecifiers.html),
/// Cocoa Scripting Guide).
@MainActor
package class VMScriptContainer: NSObject {
    nonisolated private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMScriptContainer")

    package nonisolated override func indicesOfObjects(
        byEvaluatingObjectSpecifier specifier: NSScriptObjectSpecifier
    ) -> [NSNumber]? {
        indices(evaluating: specifier, in: self)
    }

    /// The indices `specifier` names, evaluated against `container` — this
    /// object, or the application whose elements it supplies — once each name
    /// that bounds it is resolved among this object's elements; `nil`, for
    /// Cocoa to evaluate it, where no name bounds it.
    ///
    /// Cocoa evaluates what the names resolved to: the range's other end,
    /// reversed ends, `before` and `after`. A refused name, or an evaluation
    /// that fails, answers no index with the refusal on the command being
    /// answered.
    nonisolated func indices(evaluating specifier: NSScriptObjectSpecifier, in container: NSObject) -> [NSNumber]? {
        // Cocoa's own evaluation of a range's named end, or of a named base,
        // takes the first element whose name matches without calling the
        // accessor (observed on macOS 27).
        var listings: [String: [NSObject]] = [:]
        let resolved: NSScriptObjectSpecifier
        switch specifier {
        case let range as NSRangeSpecifier:
            guard range.startSpecifier is NSNameSpecifier || range.endSpecifier is NSNameSpecifier,
                let description = range.containerClassDescription
            else { return nil }
            guard case .reads(let start, let startNamed) = bound(range.startSpecifier, listings: &listings),
                case .reads(let end, let endNamed) = bound(range.endSpecifier, listings: &listings)
            else { return [] }
            guard startNamed || endNamed else { return nil }
            resolved = NSRangeSpecifier(
                containerClassDescription: description, containerSpecifier: nil, key: range.key, start: start,
                end: end)
        case let relative as NSRelativeSpecifier:
            guard relative.baseSpecifier is NSNameSpecifier, let description = relative.containerClassDescription
            else { return nil }
            guard case .reads(let base, let named) = bound(relative.baseSpecifier, listings: &listings) else {
                return []
            }
            guard named else { return nil }
            resolved = NSRelativeSpecifier(
                containerClassDescription: description, containerSpecifier: nil, key: relative.key,
                relativePosition: relative.relativePosition, baseSpecifier: base)
        default:
            return nil
        }
        var count = 0
        guard let indices = resolved.indicesOfObjectsByEvaluating(withContainer: container, count: &count) else {
            Self.refuse(VMScriptEvaluationFailure(resolved).number)
            return []
        }
        return (0..<count).map { NSNumber(value: indices[$0]) }
    }

    /// What a range's end or a relative specifier's base reads as once its
    /// name is resolved.
    private enum Bound {
        /// `specifier`, the index of the element its name resolved to where
        /// `named`, or as written.
        case reads(_ specifier: NSScriptObjectSpecifier?, named: Bool)
        /// Its name names nothing, with the refusal on the command being
        /// answered.
        case refused
    }

    /// `end` with its name resolved among this object's elements by their
    /// accessor, sharing `listings` with the other ends of one evaluation; as
    /// written when it is no name or its elements have no accessor.
    nonisolated private func bound(_ end: NSScriptObjectSpecifier?, listings: inout [String: [NSObject]]) -> Bound {
        guard let named = end as? NSNameSpecifier else { return .reads(end, named: false) }
        let key = named.key
        let accessor = NSSelectorFromString("valueIn" + key.prefix(1).uppercased() + key.dropFirst() + "WithName:")
        guard responds(to: accessor) else { return .reads(end, named: false) }
        // Cocoa refuses a range whose end names a container of its own
        // (errAEImpossibleRange, observed on macOS 27); such a base is
        // refused alike.
        guard named.container == nil else {
            Self.refuse(Int(errAEImpossibleRange))
            return .refused
        }
        guard let found = value(withName: named.name, inPropertyWithKey: key) as? NSObject else { return .refused }
        let listed = listings[key] ?? (value(forKey: key) as? [NSObject] ?? [])
        listings[key] = listed
        guard let index = Self.index(of: found, in: listed), let description = named.containerClassDescription else {
            Self.logger.log(
                .fault, "The \(key, privacy: .public) accessor answered an element its container doesn't list")
            assertionFailure("The \(key) accessor answered an element its container doesn't list")
            Self.refuse(Int(errAENoSuchObject))
            return .refused
        }
        let resolved = NSIndexSpecifier(
            containerClassDescription: description, containerSpecifier: nil, key: key, index: index)
        resolved.containerIsRangeContainerObject = named.containerIsRangeContainerObject
        return .reads(resolved, named: true)
    }

    /// Where `element` is in `listed`: the element there that its own
    /// reference names, and none for an element with no reference.
    nonisolated private static func index(of element: NSObject, in listed: [NSObject]) -> Int? {
        guard let reference = element.objectSpecifier else { return nil }
        return listed.firstIndex { $0.objectSpecifier.map { isOneElement($0, reference) } ?? false }
    }

    /// Whether the references `a` and `b` name one element: the same form,
    /// key and value, in the same container.
    nonisolated private static func isOneElement(_ a: NSScriptObjectSpecifier, _ b: NSScriptObjectSpecifier) -> Bool {
        guard type(of: a) == type(of: b), a.key == b.key else { return false }
        switch (a.container, b.container) {
        case (nil, nil): break
        case let (aContainer?, bContainer?): guard isOneElement(aContainer, bContainer) else { return false }
        default: return false
        }
        switch (a, b) {
        case let (a as NSUniqueIDSpecifier, b as NSUniqueIDSpecifier):
            return (a.uniqueID as AnyObject).isEqual(b.uniqueID)
        case let (a as NSNameSpecifier, b as NSNameSpecifier):
            return a.name == b.name
        case let (a as NSIndexSpecifier, b as NSIndexSpecifier):
            return a.index == b.index
        default:
            return false
        }
    }

    /// Records `number` on the command being answered, unless it carries a
    /// refusal already; the script reads it with the reference Cocoa names.
    nonisolated private static func refuse(_ number: Int) {
        guard let command = NSScriptCommand.current(), command.scriptErrorNumber == 0 else { return }
        command.scriptErrorNumber = number
    }
}

/// The application as the dictionary's root: a specifier of an element its
/// delegate supplies (`application(_:delegateHandlesKey:)`) is the delegate's
/// to resolve, as the ``VMScriptContainer`` that element lives in, evaluated
/// against the application.
///
/// Adds no stored property, so the test host can make its application one in
/// place (`object_setClass`).
@objc(VMScriptingApplication)
public class VMScriptingApplication: NSApplication {
    override public nonisolated func indicesOfObjects(
        byEvaluatingObjectSpecifier specifier: NSScriptObjectSpecifier
    ) -> [NSNumber]? {
        let key = specifier.key
        let root = MainActor.assumeIsolated { () -> VMScriptingRoot? in
            guard let root = delegate as? VMScriptingRoot, root.application(self, delegateHandlesKey: key) else {
                return nil
            }
            return root
        }
        return root?.indices(evaluating: specifier, in: self)
    }
}
