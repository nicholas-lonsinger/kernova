// The adapters land and serve through POSIX directories, which only Darwin and Linux have here.
#if canImport(Darwin) || os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import KernovaAgentCore
import KernovaAgentRuntime
import KernovaContainer
import KernovaContainerPipeline
import KernovaFileTree
import KernovaTreeTransfer
import KernovaWire

/// Serves this side's offers as `ItemSourceEffect` asks: each pull's container encoded from its content — a tree
/// read by `TreeReader`, or INLINE bytes as one DATA entry — compressed as `TransferCompression` chooses for the
/// direction this side's role on the pull's connection sends it. Each pull's work runs on a queue of its own.
public final class ItemSourceAdapter<FileSystem: TreeFileSystem & Sendable>: ItemSource {
    /// Produces the content of the offered representation a pull names, of an offer of the feature it names, or
    /// why it cannot: called on the pull's own queue, so it may wait, as a promise called in does.
    public typealias Content = @Sendable (FeatureID, PullRequest, Representation) -> Result<ItemContent, WireError>

    private final class Serve {
        let events: any TreeEventSource
        let encoder: ContainerEncodePipeline
        let acceptance: ContainerAcceptance
        /// Encoded bytes not yet read.
        var pending = Data()
        var ended = false
        var failed = false

        init(events: any TreeEventSource, encoder: ContainerEncodePipeline, acceptance: ContainerAcceptance) {
            self.events = events
            self.encoder = encoder
            self.acceptance = acceptance
        }
    }

    private let fileSystem: FileSystem
    private let sendingCores: Int
    private let content: Content
    private let serves = PullLanes<Serve>(label: "app.kernova.item-source")

    /// A source serving what `content` produces, read through `fileSystem`.
    ///
    /// - Parameters:
    ///   - fileSystem: The calls a tree's read makes.
    ///   - sendingCores: The active cores compression may use.
    ///   - content: The content of each pulled representation.
    public init(
        fileSystem: FileSystem, sendingCores: Int = ProcessInfo.processInfo.activeProcessorCount,
        content: @escaping Content
    ) {
        self.fileSystem = fileSystem
        self.sendingCores = sendingCores
        self.content = content
    }

    /// Carries out `effect` on its pull's queue, answering through `reporter`.
    public func handle(_ effect: ItemSourceEffect, reporter: ItemSourceReporter) {
        switch effect {
        case .serve(let id, let feature, let request, let representation):
            let compression = TransferCompression.forSending(
                TransferDirection(servedBy: reporter.connection.role), pullAcceptsLZ4: request.codecs.contains(.lz4),
                sendingCores: sendingCores)
            let acceptance = compression.sending(ContainerAcceptance(request, storage: representation.storage))
            serves.open(PullKey(connection: reporter.connection, id: id)) { [fileSystem, content] in
                switch Self.events(content(feature, request, representation), acceptance, fileSystem) {
                case .success(let events):
                    return Serve(
                        events: events,
                        encoder: ContainerEncodePipeline(
                            accepting: acceptance, policy: compression.chunkPolicy,
                            workers: compression.encodingWorkers),
                        acceptance: acceptance)
                case .failure(let error):
                    reporter.report(.failed(id, error))
                    return nil
                }
            }
        case .read(let id, let maxBytes):
            serves.run(PullKey(connection: reporter.connection, id: id)) { serve in
                guard !serve.failed else { return }
                do throws(WireError) {
                    while serve.pending.count < maxBytes, !serve.ended {
                        guard let event = try serve.events.nextEvent() else {
                            serve.ended = true
                            break
                        }
                        do throws(ContainerError) {
                            serve.pending.append(try serve.encoder.encode(event))
                        } catch {
                            throw error.wireError(serve.acceptance)
                        }
                    }
                } catch {
                    serve.failed = true
                    serve.pending = Data()
                    return reporter.report(.failed(id, error))
                }
                guard !serve.pending.isEmpty else { return reporter.report(.finished(id)) }
                let count = min(maxBytes, serve.pending.count)
                let bytes = Data(serve.pending.prefix(count))
                serve.pending = Data(serve.pending.dropFirst(count))
                reporter.report(.bytes(id, bytes))
            }
        case .release(let id):
            serves.close(PullKey(connection: reporter.connection, id: id))
        }
    }

    /// The events of `content`'s container, held to `acceptance`.
    private static func events(
        _ content: Result<ItemContent, WireError>, _ acceptance: ContainerAcceptance, _ fileSystem: FileSystem
    ) -> Result<any TreeEventSource, WireError> {
        switch (content, acceptance.storage) {
        case (.failure(let error), _):
            return .failure(error)
        case (.success(.inline(let bytes)), .inline):
            return .success(InlineEvents(bytes, acceptance: acceptance))
        case (.success(.tree(let path)), .file), (.success(.tree(let path)), .folder):
            do throws(TreeReadFailure) {
                return .success(try TreeReader(fileSystem: fileSystem, root: Array(path.utf8), accepting: acceptance))
            } catch {
                return .failure(WireError(received: error.wireError))
            }
        case (.success(let content), let storage):
            return .failure(
                WireError(.itemRepresentationUnavailable, debugDetail: "\(content) for \(storage) storage"))
        }
    }
}

extension TransferDirection {
    /// The way a container a side of `role` serves travels.
    init(servedBy role: PeerRole) {
        switch role {
        case .host: self = .hostToGuest
        case .sessionPeer, .systemPeer: self = .guestToHost
        }
    }
}

/// What a source reads a container's events from.
protocol TreeEventSource: AnyObject {
    /// The next event, or nil after `.end`.
    func nextEvent() throws(WireError) -> TreeEvent?
}

extension TreeReader: TreeEventSource {
    func nextEvent() throws(WireError) -> TreeEvent? {
        do {
            return try next()
        } catch {
            throw WireError(received: error.wireError)
        }
    }
}

/// An INLINE representation's bytes as the events of one DATA entry, its bytes in chunks the size a reader's are.
final class InlineEvents: TreeEventSource {
    private let bytes: Data
    private let header: EntryHeader
    /// The offset of the next chunk; nil before the header goes.
    private var offset: Int?
    private var finished = false
    private var ended = false

    init(_ bytes: Data, acceptance: ContainerAcceptance) {
        self.bytes = bytes
        var header = EntryHeader()
        header.type = .data
        if acceptance.acceptsLZ4 {
            header.lz4.size = UInt64(bytes.count)
        } else {
            header.plain.size = UInt64(bytes.count)
        }
        self.header = header
    }

    func nextEvent() throws(WireError) -> TreeEvent? {
        guard let start = offset else {
            offset = bytes.startIndex
            return .beginFile(header)
        }
        if start < bytes.endIndex {
            let end = min(start + ContainerEncoder.chunkByteCount, bytes.endIndex)
            offset = end
            return .bytes(bytes.subdata(in: start..<end))
        }
        if !finished {
            finished = true
            return .finishFile
        }
        guard !ended else { return nil }
        ended = true
        return .end
    }
}
#endif
