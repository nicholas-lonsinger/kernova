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
    /// Answers the host's `DragResolve`: the catcher will call the drag's
    /// promises in when the drop lands on it — the one step after which the
    /// host releases the guest's button to resolve them.
    case resolving
    /// Answers a `DragResolve` the catcher will not act on, leaving its take
    /// as it was: unlike ``failed(_:message:)``, it says nothing about the
    /// hand-off.
    case resolveRefused
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
        case .resolving: self = .resolving
        case .resolveRefused: self = .resolveRefused
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
    ///
    /// `nil` for a promised item, which has no name until the guest calls it
    /// in — ``ClipboardEndpoint/resolveDragName(generation:repIndex:deadline:releasingGuestButton:)``.
    public let filename: String?
    /// A type conforming to `public.data` for a file, or to `public.directory`
    /// for a folder — `NSFilePromiseProvider` raises for a file type that
    /// conforms to neither.
    public let type: UTType
    /// Whether the item is a folder (or package), which arrives as its tree.
    public let isDirectory: Bool
    /// Whether the guest carries the item as a file promise its source writes
    /// only once a destination calls it in.
    public let isPromised: Bool

    /// The item the guest declared at `repIndex`, made safe.
    public init(
        repIndex: Int, declared info: Kernova_V1_ClipboardRepresentationInfo, isPromised: Bool
    ) {
        self.repIndex = repIndex
        self.filename =
            isPromised ? nil : Self.safeFilename(info.filename, isDirectory: info.isDirectory)
        self.type = Self.usableType(info.uti, isDirectory: info.isDirectory)
        self.isDirectory = info.isDirectory
        self.isPromised = isPromised
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

/// One item of a drag the guest offers.
public enum ClipboardDragOutItem: Sendable {
    /// A file or folder already on disk.
    case file(ClipboardContent.Representation)
    /// A file promise, whose source writes the item only once a destination
    /// calls it in: `uti` is its promised type, and `isDirectory` whether that
    /// type conforms to `public.directory`.
    case promise(uti: String, isDirectory: Bool)
}

/// Why naming a drag's promised items failed.
public enum ClipboardDragNamingFailure: Error, Equatable, Sendable {
    /// The guest answered with `STAGE_FAILED`; `code` is `nil` for one this
    /// build does not define.
    case handOffFailed(ClipboardErrorCode?)
    /// The guest's catcher refused the `DragResolve` (`STAGE_RESOLVE_REFUSED`).
    case resolveRefused
    /// The guest said this item will not be named; the drag's other items
    /// may still be.
    case unnamed
    /// The connection ended.
    case sessionEnded
    /// The drag is not live on this connection: retired, withdrawn, or never
    /// offered here.
    case dragNotLive
    /// A caller's deadline passed first.
    case timedOut
}
