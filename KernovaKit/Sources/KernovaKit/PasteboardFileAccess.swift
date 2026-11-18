import AppKit
import Foundation

/// The grants of access to files and folders this process took reading one pasteboard generation's
/// `public.file-url`s, held while anything holds this and given back once nothing does.
///
/// Only the first read of an item's `public.file-url` in a generation takes a grant: a later one takes none, even once
/// that grant is given back (docs/research/2026-11-18-pasteboard-file-grants.md). So every read of a generation
/// shares this one access while it lives, and whatever serves a transfer of its files holds it for as long as the
/// transfer can reach them — an offer read from it (``ClipboardOfferSource``), and a clipboard end while its
/// pasteboard stands at the generation, since reading that again reaches nothing once its grants are given back.
@MainActor
public final class PasteboardFileAccess {
    /// What this process read of one pasteboard generation.
    private final class Generation {
        weak var pasteboard: (any ClipboardReadPasteboard)?
        let changeCount: Int
        /// The items whose `public.file-url` this process has read in the generation, granted or not.
        var read: Set<Int> = []
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
    private var granted: [URL] = []

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
        grants.pasteboardGranted(url)
        granted.append(url)
        return string
    }

    /// Whether this holds any grant.
    public var holdsGrants: Bool { !granted.isEmpty }

    /// Whether the pasteboard read still stands at the generation it read.
    public var standsOnItsPasteboard: Bool {
        generation.pasteboard.map { $0.changeCount == generation.changeCount } ?? false
    }

    isolated deinit {
        for url in granted { grants.pasteboardGrantReleased(url) }
    }
}
