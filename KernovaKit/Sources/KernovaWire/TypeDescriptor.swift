/// A vocabulary of native type names, and the prefix that namespaces its names
/// in `TypeDescriptor.native`.
public enum NativeTypeNamespace: String, Sendable, CaseIterable {
    /// Apple Uniform Type Identifiers (`public.png`).
    case appleUTI = "apple-uti"
    /// Windows clipboard format names (`PNG`, `CF_UNICODETEXT`).
    case windowsClipboardFormat = "win-cf"

    /// `name` in this namespace, as `TypeDescriptor.native` carries it.
    public func qualified(_ name: String) -> String {
        rawValue + "/" + name
    }
}

extension Kernova_V2_Item {
    /// The representation a destination accepting `accepted` takes, as an index
    /// into `representations`; nil when none fits.
    ///
    /// A shared native name decides first: the destination's earliest accepted
    /// type that shares one with some representation picks the earliest such
    /// representation. Only when no native name is shared does an equal,
    /// non-empty MIME type decide, in the same order. A representation whose
    /// storage is not a recognized one is never chosen.
    public func representationIndex(accepting accepted: [TypeDescriptor]) -> Int? {
        let offered = representations.indices.filter {
            switch representations[$0].storage {
            case .inline, .file, .folder: true
            case .unspecified, .UNRECOGNIZED: false
            }
        }
        for wanted in accepted {
            let names = Set(wanted.native)
            if let index = offered.first(where: { !names.isDisjoint(with: representations[$0].type.native) }) {
                return index
            }
        }
        for wanted in accepted where !wanted.mime.isEmpty {
            if let index = offered.first(where: { representations[$0].type.mime == wanted.mime }) {
                return index
            }
        }
        return nil
    }
}
