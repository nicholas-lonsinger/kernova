import Foundation
import UniformTypeIdentifiers

/// What a pasteboard type name stands for to AppKit, whatever its spelling.
///
/// AppKit matches a declared type case-insensitively (`PUBLIC.FILE-URL`
/// answers `availableType(from: [.fileURL])`), and reads a `dyn.` type — its
/// prefix in any case — as the legacy pasteboard type or OSType its tags
/// encode. So a type is judged by every name it answers to: its own, its
/// declared identifier, and each legacy name and OSType its tags carry,
/// followed through to what they name in turn.
struct PasteboardTypeIdentity {
    private static var pasteboardTagClass: UTTagClass { UTTagClass(rawValue: "com.apple.nspboard-type") }
    private static var ostypeTagClass: UTTagClass { UTTagClass(rawValue: "com.apple.ostype") }

    /// The names that hand a pasteboard reader a file on this machine, or a
    /// promise of one, lowercased. Undeclared names are listed here because no
    /// conformance reaches them.
    private static let fileReferenceNames: Set<String> = [
        "public.file-url",
        "nsfilenamespboardtype",
        "nsfilenamepboardtype",
        "next filename pasteboard type",
        "com.apple.finder.node",
        "com.apple.finder.noderef",
        "nsfilespromisepboardtype",
        "apple files promise pasteboard type",
        "apple hfs promise pasteboard type",
        "com.apple.pasteboard.nsfilepromiseid",
        "corepasteboardflavortype 0x6675726c",  // 'furl'
        "corepasteboardflavortype 0x68667320",  // 'hfs '
        "corepasteboardflavortype 0x70686673",  // 'phfs'
        "corepasteboardflavortype 0x616c6973",  // 'alis'
        "corepasteboardflavortype 0x66737320",  // 'fss '
        "corepasteboardflavortype 0x66737266",  // 'fsrf'
    ]
    /// Prefixes of the same, lowercased: the promise types
    /// `NSFilePromiseProvider` writes and `NSTypedFilenamesPboardType:<ext>`.
    private static let fileReferencePrefixes = [
        "com.apple.pasteboard.promised-", "com.apple.nsfilepromise", "nstypedfilenamespboardtype:",
    ]
    private static let fileReferenceOSTypes: Set<String> = ["furl", "hfs ", "phfs", "alis", "fss ", "fsrf"]

    /// Legacy names AppKit reads a URL from, lowercased.
    private static let urlNames: Set<String> = [
        "apple url pasteboard type",
        "nsurlpboardtype",
        "corepasteboardflavortype 0x75726c20",  // 'url '
        "corepasteboardflavortype 0x6775726c",  // 'gurl'
    ]
    private static let urlOSTypes: Set<String> = ["url ", "gurl"]
    /// Legacy names carrying `[urls, titles]`, lowercased.
    private static let titledURLNames: Set<String> = ["weburlswithtitlespboardtype"]

    /// Names AppKit reads RTFD from, lowercased.
    private static let rtfdNames: Set<String> = [
        "com.apple.flat-rtfd",
        "com.apple.rtfd",
        "next rtfd pasteboard type",
        "nsrtfdpboardtype",
        "corepasteboardflavortype 0x72746664",  // 'rtfd'
        "corepasteboardflavortype 0x52544644",  // 'RTFD'
    ]
    private static let rtfdOSTypes: Set<String> = ["rtfd"]

    private static let markerPrefix = "org.nspasteboard."

    /// Every name the type answers to, lowercased.
    private let names: [String]
    private let ostypes: [String]
    private let type: UTType?
    /// The identities its legacy-name tags encode.
    private let encoded: [PasteboardTypeIdentity]
    /// A `dyn.` type whose encoding names nothing, so it could stand for any
    /// type.
    private let isOpaqueDynamic: Bool

    init(_ name: String) {
        let isDynamic = name.lowercased().hasPrefix("dyn.")
        // The prefix is matched in any case; the encoding after it is not.
        let type = isDynamic ? UTType("dyn." + name.dropFirst(4)) : UTType(name)
        let tags = type?.tags ?? [:]
        let legacyNames = tags[Self.pasteboardTagClass] ?? []
        self.type = type
        ostypes = tags[Self.ostypeTagClass] ?? []
        names =
            [name.lowercased()] + [type?.identifier.lowercased()].compactMap { $0 }
            + legacyNames.map { $0.lowercased() }
        // Only a `dyn.` type's tags are followed: each is shorter than the
        // encoding carrying it, and an OSType leads to a declared type, so
        // following ends. A declared type's own tags lead back to itself.
        encoded =
            isDynamic
            ? legacyNames.map(PasteboardTypeIdentity.init)
                + ostypes.compactMap { UTType(tag: $0, tagClass: Self.ostypeTagClass, conformingTo: nil) }
                .filter { !$0.isDynamic }.map { PasteboardTypeIdentity($0.identifier) }
            : []
        isOpaqueDynamic = isDynamic && tags.isEmpty
    }

    /// An `org.nspasteboard.*` marker: metadata about the content, not
    /// content.
    var isMarker: Bool {
        names.contains { $0.hasPrefix(Self.markerPrefix) } || encoded.contains(where: \.isMarker)
    }

    /// A file on this machine, a promise of one, data the system resolves to
    /// one (an alias, a bookmark, a Finder node), or a `dyn.` type too opaque
    /// to rule any out.
    var isFileReference: Bool {
        isOpaqueDynamic || type?.conforms(to: .fileURL) == true
            || type?.conforms(to: .resolvable) == true
            || names.contains { name in
                Self.fileReferenceNames.contains(name) || Self.fileReferencePrefixes.contains { name.hasPrefix($0) }
            }
            || ostypes.contains { Self.fileReferenceOSTypes.contains($0.lowercased()) }
            || encoded.contains(where: \.isFileReference)
    }

    /// A type AppKit reads a URL from, so its bytes can name a file whatever
    /// the type is.
    var carriesURL: Bool {
        type?.conforms(to: .url) == true || names.contains(where: Self.urlNames.contains)
            || carriesTitledURLs
            || ostypes.contains { Self.urlOSTypes.contains($0.lowercased()) }
            || encoded.contains(where: \.carriesURL)
    }

    /// A URL type whose property list is `[urls, titles]`, so only its first
    /// array holds URLs.
    var carriesTitledURLs: Bool {
        names.contains(where: Self.titledURLNames.contains) || encoded.contains(where: \.carriesTitledURLs)
    }

    /// RTFD in any spelling: a serialized file wrapper whose members a reader
    /// opens, so a symbolic link among them names a file on this machine.
    var isRTFD: Bool {
        type.map { $0.conforms(to: .rtfd) || $0.conforms(to: .flatRTFD) } == true
            || names.contains(where: Self.rtfdNames.contains)
            || ostypes.contains { Self.rtfdOSTypes.contains($0.lowercased()) }
            || encoded.contains(where: \.isRTFD)
    }
}
