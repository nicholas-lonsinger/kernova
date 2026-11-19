import AppKit
import Foundation

/// The grants of access to files and folders this process took reading one pasteboard generation's
/// `public.file-url`s, held while anything holds this and let go once nothing does.
///
/// Only the first read of an item's `public.file-url` in a generation takes a grant: a later one takes none, even once
/// that grant is given back (docs/research/2026-11-18-pasteboard-file-grants.md). So every read of a generation
/// shares this one access while it lives, and keeps the bookmark each read makes of a file while its grant lasts,
/// which reaches the file once the grant is given back. A drop's offer holds the access for as long as the drop
/// lasts, and so does an import of what was dropped; a copy's read holds it only until it has made its bookmarks.
/// A grant is given back by path, so one whose path's folder is gone stays with the process when let go.
@MainActor
public final class PasteboardFileAccess {
    /// What this process read of one pasteboard generation.
    private final class Generation {
        weak var pasteboard: (any ClipboardReadPasteboard)?
        let changeCount: Int
        /// The items whose `public.file-url` this process has read in the generation, granted or not.
        var read: Set<Int> = []
        /// A bookmark of each item's file or folder a read made while its grant lasted, by item: how a later read of
        /// the generation reaches it once its grant is given back.
        var bookmarks: [Int: Data] = [:]
        /// The access holding the generation's grants, while anything holds it.
        weak var access: PasteboardFileAccess?

        init(pasteboard: any ClipboardReadPasteboard, changeCount: Int) {
            self.pasteboard = pasteboard
            self.changeCount = changeCount
        }
    }

    /// Each pasteboard's generation this process read last, by the pasteboard's identity.
    private static var generations: [ObjectIdentifier: Generation] = [:]

    private let generation: Generation
    private let grants: SandboxFileGrants
    private var granted: [SandboxFileGrants.Grant] = []

    private init(generation: Generation, grants: SandboxFileGrants) {
        self.generation = generation
        self.grants = grants
    }

    /// The access a read of `pasteboard` as it stands at `changeCount` takes its grants into: the one every read of
    /// that generation shares while anything holds it.
    static func reading(_ pasteboard: any ClipboardReadPasteboard, at changeCount: Int) -> PasteboardFileAccess {
        let key = ObjectIdentifier(pasteboard)
        let generation: Generation
        if let last = generations[key], last.pasteboard === pasteboard, last.changeCount == changeCount {
            if let access = last.access { return access }
            generation = last
        } else {
            generations = generations.filter { $0.value.pasteboard != nil }
            generation = Generation(pasteboard: pasteboard, changeCount: changeCount)
            generations[key] = generation
        }
        let access = PasteboardFileAccess(generation: generation, grants: pasteboard.fileGrants)
        generation.access = access
        return access
    }

    /// The `public.file-url` of `item`, the generation's item `index`, read now. The generation's first read of
    /// it took a grant of what it names, which this access holds from then on.
    func fileURL(ofItem index: Int, _ item: any ClipboardPasteboardItemReading) -> String? {
        let string = item.string(forType: .fileURL)
        guard let string, let url = URL(string: string), url.isFileURL, generation.read.insert(index).inserted
        else { return string }
        granted.append(grants.pasteboardGranted(url))
        return string
    }

    /// The file URL each of `pasteboard`'s items names as it stands now, read into the access every read of it
    /// shares, and that access, which whatever reads the files holds until it has.
    public static func readFileURLs(
        from pasteboard: any ClipboardReadPasteboard
    ) -> (urls: [URL], access: PasteboardFileAccess) {
        let access = reading(pasteboard, at: pasteboard.changeCount)
        let urls = pasteboard.items.enumerated().compactMap { index, item in
            access.fileURL(ofItem: index, item).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
        }
        return (urls, access)
    }

    /// The bookmark a read of the generation made of item `index`'s file or folder, if one did.
    func bookmark(ofItem index: Int) -> Data? {
        generation.bookmarks[index]
    }

    /// Keeps `bookmark`, of item `index`'s file or folder, for every later read of the generation.
    func keep(_ bookmark: Data, forItem index: Int) {
        generation.bookmarks[index] = bookmark
    }

    /// Whether this holds any grant.
    public var holdsGrants: Bool { !granted.isEmpty }
}
