import AppIntents
import Foundation
import UniformTypeIdentifiers

/// One virtual machine bundle on disk, as Shortcuts hands it to an action.
///
/// A file a workflow picked or produced is addressed by the framework's own
/// identifier and nothing else: the URL behind it is a read of its own, and one
/// the app may only make from inside a security-scoped bracket while the action
/// runs. The name is read once, where the entity is resolved, because that read
/// is asynchronous and a display representation is not.
struct VMBundleFile: FileEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Virtual Machine Bundle")

    /// What a file has to be for this surface to name it — the `.kernova`
    /// package an import copies into the library.
    ///
    /// Spelled out rather than taken from `UTType.kernovaVM` because the App
    /// Intents metadata extractor reads this list out of the source at build
    /// time: it resolves a system type or an `exportedAs` declaration written
    /// here, and fails the build on a named constant whose identifier it would
    /// have to run code to learn.
    static let supportedContentTypes: [UTType] = [UTType(exportedAs: "app.kernova.vm")]

    static let defaultQuery = VMBundleFileQuery()

    let id: FileEntityIdentifier

    /// The bundle's file name, `nil` for an identifier that named no file when
    /// it was resolved.
    let name: String?

    init(_ id: FileEntityIdentifier) async {
        self.id = id
        self.name = try? await id.fileURL?.lastPathComponent
    }

    var displayRepresentation: DisplayRepresentation {
        guard let name else { return DisplayRepresentation(title: "Virtual Machine Bundle") }
        return DisplayRepresentation(title: "\(name)")
    }
}

/// How Shortcuts turns a file it holds into the bundle an import acts on.
///
/// The identifier is the whole of what addresses a file entity, so resolving
/// one is reading the name behind it and nothing more — there is no library to
/// look it up in, and a file the identifier no longer names is a failure the
/// import itself reports, where the user is told what could not be copied.
struct VMBundleFileQuery: EntityQuery {
    func entities(for identifiers: [FileEntityIdentifier]) async throws -> [VMBundleFile] {
        var files: [VMBundleFile] = []
        for identifier in identifiers {
            files.append(await VMBundleFile(identifier))
        }
        return files
    }
}
