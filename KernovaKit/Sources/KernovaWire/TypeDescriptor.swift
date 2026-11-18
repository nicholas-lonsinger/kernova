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
