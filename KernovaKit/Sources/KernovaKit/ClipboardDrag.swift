import Foundation
import UniformTypeIdentifiers

/// One step of the guest handing a drag over to the host, as `DragHandOff`
/// carries it.
public enum ClipboardDragHandOffStep: Equatable, Sendable {
    /// The catcher is ordered front under the pointer.
    case armed
    /// The guest drag manager entered the catcher, which answered copy — the
    /// one step after which the host may release the guest's button.
    case targeted
    /// The guest drag ended on the catcher; its items stay pullable.
    case caught
    /// The hand-off cannot complete. `code` is `nil` for one this build does
    /// not define; `message` is peer-supplied log detail, never UI.
    case failed(ClipboardErrorCode?, message: String)

    /// The step a received `DragHandOff` reports.
    ///
    /// A stage this build does not define reads as a failure, never as a step
    /// a take could act on.
    public init(_ handOff: Kernova_V1_DragHandOff) {
        switch handOff.stage {
        case .armed: self = .armed
        case .targeted: self = .targeted
        case .caught: self = .caught
        case .failed, .unspecified, .UNRECOGNIZED:
            self = .failed(ClipboardErrorCode(rawValue: handOff.code), message: handOff.message)
        }
    }
}

/// A drag the guest offered, as the host takes it in: metadata only, every item
/// already made safe to hand to AppKit.
public struct ClipboardInboundDrag: Equatable, Sendable {
    /// The generation the guest announced it under — what a take, a pull, and
    /// ``ClipboardEndpoint/completeDrag(generation:)`` name.
    public let generation: UInt64
    /// Every dragged item, in the order the drag carried them.
    public let items: [ClipboardDraggedItem]

    /// Describes one drag.
    public init(generation: UInt64, items: [ClipboardDraggedItem]) {
        self.generation = generation
        self.items = items
    }
}

/// One item of a guest drag, with its peer-supplied name and type reduced to
/// values a file promise accepts.
public struct ClipboardDraggedItem: Equatable, Sendable {
    /// The item's index in the offer — the `repIndex` a pull names.
    public let repIndex: Int
    /// A single path component: never empty, `.`, `..`, or containing `/`.
    public let filename: String
    /// A type conforming to `public.data` for a file, or to `public.directory`
    /// for a folder — `NSFilePromiseProvider` raises for a file type that
    /// conforms to neither.
    public let type: UTType
    /// Whether the item is a folder (or package), which arrives as its tree.
    public let isDirectory: Bool

    /// The item the guest declared at `repIndex`, made safe.
    public init(repIndex: Int, declared info: Kernova_V1_ClipboardRepresentationInfo) {
        self.repIndex = repIndex
        self.filename = Self.safeFilename(info.filename, isDirectory: info.isDirectory)
        self.type = Self.usableType(info.uti, isDirectory: info.isDirectory)
        self.isDirectory = info.isDirectory
    }

    /// `filename` reduced to one safe path component, with a generic name for
    /// one that reduces to nothing.
    public static func safeFilename(_ filename: String, isDirectory: Bool) -> String {
        NameUniquing.sanitizedComponent(filename, fallback: isDirectory ? "Folder" : "File")
    }

    /// `identifier` when the system knows it as a type an item of this kind can
    /// be — data for a file, a directory for a folder, so a package keeps its
    /// type — otherwise `public.data` or `public.folder`.
    public static func usableType(_ identifier: String, isDirectory: Bool) -> UTType {
        let required: UTType = isDirectory ? .directory : .data
        guard let type = UTType(identifier), type.conforms(to: required) else {
            return isDirectory ? .folder : .data
        }
        return type
    }
}
