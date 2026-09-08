import Cocoa
import KernovaKit

/// How one Apple event addresses the VMs its verb runs on.
///
/// The specifier is read *unevaluated* wherever it names a VM on its own: a
/// name reaches the core as ``VMSelector/name(_:)``, so a name several VMs
/// answer to is refused by the core with the candidates listed, rather than
/// resolving to whichever one the container handed back first. Everything else
/// a specifier can say — an index, a range, `every`, a `whose` test — only
/// Cocoa can read, so those are evaluated and each VM addressed by identifier.
enum VMScriptSelector {
    /// The VMs an event addressed, in the order it named them.
    ///
    /// `specifier` is what the event carried, unevaluated; `receivers` is what
    /// Cocoa resolved it to, for the forms only an evaluation can read. Empty
    /// when neither names a VM this app can resolve, which is the caller's cue
    /// to refuse.
    static func selectors(
        addressing specifier: NSScriptObjectSpecifier?, resolving receivers: Any?
    ) -> [VMSelector] {
        if let specifier, let named = selector(naming: specifier) {
            return [named]
        }
        return resolved(receivers)
    }

    /// The VM this specifier names by itself, `nil` when reading it takes an
    /// evaluation.
    private static func selector(naming specifier: NSScriptObjectSpecifier) -> VMSelector? {
        switch specifier {
        case let unique as NSUniqueIDSpecifier:
            // A dictionary `id` is text, so anything else came from a script
            // naming an identifier this app never issued: let the evaluation
            // refuse it rather than inventing a selector.
            guard let text = unique.uniqueID as? String, let id = UUID(uuidString: text) else {
                return nil
            }
            return .id(id)
        case let named as NSNameSpecifier:
            return .name(named.name)
        default:
            return nil
        }
    }

    /// The VMs Cocoa resolved `receivers` to, each addressed by identifier.
    private static func resolved(_ receivers: Any?) -> [VMSelector] {
        switch receivers {
        case let vm as VMScriptObject:
            [vm.selector]
        case let list as [Any]:
            list.flatMap { resolved($0) }
        default:
            []
        }
    }
}
