import Foundation
import KernovaWire
import UniformTypeIdentifiers

extension TypeDescriptor {
    /// The descriptor of a pasteboard type: its UTI as the native name, and its
    /// preferred MIME type when one names it.
    ///
    /// A dynamic (`dyn.*`) identifier travels as it is, so a legacy pasteboard
    /// type round-trips exactly between two Macs.
    public init(appleUTI uti: String) {
        self.init()
        native = [NativeTypeNamespace.appleUTI.qualified(uti)]
        // The wire's MIME type carries no parameters; UTType's text types add `;charset=`.
        let preferred = UTType(uti)?.preferredMIMEType ?? ""
        mime = preferred.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The pasteboard type this descriptor names on a Mac: its first Apple UTI,
    /// or else the declared type its MIME type maps to; nil when neither names
    /// one.
    public var appleUTI: String? {
        let prefix = NativeTypeNamespace.appleUTI.qualified("")
        if let name = native.first(where: { $0.hasPrefix(prefix) && $0.count > prefix.count }) {
            return String(name.dropFirst(prefix.count))
        }
        guard !mime.isEmpty, let type = UTType(mimeType: mime), !type.isDynamic else { return nil }
        return type.identifier
    }
}
