import Cocoa
import KernovaLogging

/// A dictionary object that holds elements: a name a script gives one of them
/// resolves by the container's `valueIn<Key>WithName:` accessor, the one name
/// rule for that element, wherever the reference puts it — alone, at either
/// end of a range, or as what `before` or `after` counts from — and a name the
/// accessor refuses names nothing. An element without an accessor is Cocoa's
/// to evaluate.
///
/// Cocoa offers a container every specifier of its elements before evaluating
/// it itself ([NSNameSpecifier](https://developer.apple.com/documentation/foundation/nsnamespecifier):
/// "As is the case when evaluating any script object specifier, the container
/// of the specified object is given a chance to evaluate the object
/// specifier"), a range's ends included: "These specifiers are evaluated in
/// the context of the same container object as the range specifier itself"
/// ([NSRangeSpecifier](https://developer.apple.com/documentation/foundation/nsrangespecifier)).
@MainActor
package class VMScriptContainer: NSObject {
    nonisolated private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMScriptContainer")

    /// The index of the element a name specifier names, and `nil` — Cocoa's
    /// own evaluation — for any other specifier.
    package nonisolated override func indicesOfObjects(
        byEvaluatingObjectSpecifier specifier: NSScriptObjectSpecifier
    ) -> [NSNumber]? {
        // Cocoa's own evaluation of a range's end, or of what `before` or
        // `after` counts from, calls no accessor: it answers the first
        // element whose name matches (observed on macOS 27).
        guard let named = specifier as? NSNameSpecifier else { return nil }
        return indices(naming: named)
    }

    /// The index of the one element `named` names under its key, as the key's
    /// accessor resolves it: none for a name the accessor refuses, which it
    /// recorded on the command being answered.
    nonisolated private func indices(naming named: NSNameSpecifier) -> [NSNumber]? {
        let key = named.key
        let accessor = NSSelectorFromString("valueIn" + key.prefix(1).uppercased() + key.dropFirst() + "WithName:")
        guard responds(to: accessor) else { return nil }
        guard let found = value(withName: named.name, inPropertyWithKey: key) as? NSObject else { return [] }
        let listed = value(forKey: key) as? [NSObject] ?? []
        guard let index = listed.firstIndex(where: { Self.isOneElement($0.objectSpecifier, found.objectSpecifier) })
        else {
            Self.logger.log(
                .fault, "The \(key, privacy: .public) accessor answered an element its container doesn't list")
            assertionFailure("The \(key) accessor answered an element its container doesn't list")
            return []
        }
        return [NSNumber(value: index)]
    }

    /// Whether the references `a` and `b` name one element: the same form,
    /// key and value, in the same container. Each element's own reference
    /// names it alone.
    nonisolated private static func isOneElement(
        _ a: NSScriptObjectSpecifier?, _ b: NSScriptObjectSpecifier?
    ) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        guard type(of: a) == type(of: b), a.key == b.key, isOneElement(a.container, b.container) else {
            return false
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
}

/// The application as the dictionary's root: a specifier of an element its
/// delegate supplies (`application(_:delegateHandlesKey:)`) is the delegate's
/// to evaluate, as the ``VMScriptContainer`` that element lives in.
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
        return root?.indicesOfObjects(byEvaluatingObjectSpecifier: specifier)
    }
}
