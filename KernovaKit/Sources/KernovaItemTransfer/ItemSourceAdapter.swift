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
import KernovaLogging
import KernovaTreeTransfer
import KernovaWire

/// Serves this side's offers as `ItemSourceEffect` asks: each pull's container encoded from its content — a tree
/// read by `TreeReader`, or INLINE bytes as one DATA entry — compressed as `TransferCompression` chooses for the
/// direction this side's role on the pull's connection sends it. Each pull's work runs on a queue of its own,
/// downloading what it reads when it is dataless (`DatalessMaterialization.on`): a pull is when its bytes move.
/// A pull whose tree cannot be read is logged here, the one place every serve's failure passes.
public final class ItemSourceAdapter<FileSystem: TreeFileSystem & Sendable>: ItemSource {
    /// Produces the content of the offered representation pull `ItemPullID` names, of an offer of the feature
    /// it names, or why it cannot: called on the pull's own queue, so it may wait, as a promise called in does,
    /// until the pull's `.serveEnded`.
    public typealias Content =
        @Sendable (FeatureID, ItemPullID, PullRequest, Representation) -> Result<ItemContent, WireError>

    private final class Serve {
        let feature: FeatureID
        let events: any TreeEventSource
        let encoder: ContainerEncodePipeline
        let acceptance: ContainerAcceptance
        /// Encoded bytes not yet read.
        var pending = Data()
        var ended = false
        var failed = false

        init(
            feature: FeatureID, events: any TreeEventSource, encoder: ContainerEncodePipeline,
            acceptance: ContainerAcceptance
        ) {
            self.feature = feature
            self.events = events
            self.encoder = encoder
            self.acceptance = acceptance
        }
    }

    private let fileSystem: FileSystem
    private let sendingCores: Int
    private let content: Content
    private let logger: KernovaLogger
    private let serves = PullLanes<Serve>(label: "app.kernova.item-source")

    /// A source serving what `content` produces, read through `fileSystem`.
    ///
    /// - Parameters:
    ///   - fileSystem: The calls a tree's read makes.
    ///   - sendingCores: The active cores compression may use.
    ///   - logger: Where a pull whose tree cannot be read is logged.
    ///   - content: The content of each pulled representation.
    public init(
        fileSystem: FileSystem, sendingCores: Int = ProcessInfo.processInfo.activeProcessorCount,
        logger: KernovaLogger, content: @escaping Content
    ) {
        self.fileSystem = fileSystem
        self.sendingCores = sendingCores
        self.logger = logger
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
            serves.open(PullKey(connection: reporter.connection, id: id)) { [fileSystem, content, logger] in
                DatalessMaterialization.on.during {
                    switch Self.events(content(feature, id, request, representation), acceptance, fileSystem) {
                    case .success(let events):
                        return Serve(
                            feature: feature, events: events,
                            encoder: ContainerEncodePipeline(
                                accepting: acceptance, policy: compression.chunkPolicy,
                                workers: compression.encodingWorkers),
                            acceptance: acceptance)
                    case .failure(let failure):
                        Self.fail(id, of: feature, failure, reporter: reporter, logger: logger)
                        return nil
                    }
                }
            }
        case .read(let id, let maxBytes):
            serves.run(PullKey(connection: reporter.connection, id: id)) { [logger] serve in
                DatalessMaterialization.on.during {
                    Self.read(serve, maxBytes: maxBytes, id: id, reporter: reporter, logger: logger)
                }
            }
        case .release(let id):
            serves.close(PullKey(connection: reporter.connection, id: id))
        }
    }

    /// Reads up to `maxBytes` more of `serve`'s container, reporting them, the pull's end, or its failure.
    private static func read(
        _ serve: Serve, maxBytes: Int, id: ItemPullID, reporter: ItemSourceReporter, logger: KernovaLogger
    ) {
        guard !serve.failed else { return }
        do throws(ServeFailure) {
            while serve.pending.count < maxBytes, !serve.ended {
                guard let event = try serve.events.nextEvent() else {
                    serve.ended = true
                    break
                }
                do throws(ContainerError) {
                    serve.pending.append(try serve.encoder.encode(event))
                } catch {
                    throw .refused(error.wireError(serve.acceptance))
                }
            }
        } catch {
            serve.failed = true
            serve.pending = Data()
            return fail(id, of: serve.feature, error, reporter: reporter, logger: logger)
        }
        guard !serve.pending.isEmpty else { return reporter.report(.finished(id)) }
        let count = min(maxBytes, serve.pending.count)
        let bytes = Data(serve.pending.prefix(count))
        serve.pending = Data(serve.pending.dropFirst(count))
        reporter.report(.bytes(id, bytes))
    }

    /// Reports that pull `id` of an offer of `feature` failed for `failure`, logging a tree that could not be
    /// read: every serve's failure is reported here.
    private static func fail(
        _ id: ItemPullID, of feature: FeatureID, _ failure: ServeFailure, reporter: ItemSourceReporter,
        logger: KernovaLogger
    ) {
        if case .read(let unread) = failure {
            let path = unread.path.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
            logger.log(
                .error,
                "A \(feature, privacy: .public) pull couldn't read '\(path, privacy: .private)': \(unread.reason.description, privacy: .public)"
            )
        }
        reporter.report(.failed(id, failure.wireError))
    }

    /// The events of `content`'s container, held to `acceptance`.
    private static func events(
        _ content: Result<ItemContent, WireError>, _ acceptance: ContainerAcceptance, _ fileSystem: FileSystem
    ) -> Result<any TreeEventSource, ServeFailure> {
        switch (content, acceptance.storage) {
        case (.failure(let error), _):
            return .failure(.refused(error))
        case (.success(.inline(let bytes)), .inline):
            return .success(InlineEvents(bytes, acceptance: acceptance))
        case (.success(.tree(let path)), .file), (.success(.tree(let path)), .folder):
            do throws(TreeReadFailure) {
                return .success(try TreeReader(fileSystem: fileSystem, root: Array(path.utf8), accepting: acceptance))
            } catch {
                return .failure(.read(error))
            }
        case (.success(let content), let storage):
            return .failure(
                .refused(WireError(.itemRepresentationUnavailable, debugDetail: "\(content) for \(storage) storage")))
        }
    }
}

/// Why a pull cannot be served.
enum ServeFailure: Error {
    /// Its tree could not be read.
    case read(TreeReadFailure)
    /// Anything else: the error the pull fails with.
    case refused(WireError)

    /// The error the pull fails with.
    var wireError: WireError {
        switch self {
        case .read(let failure): WireError(received: failure.wireError)
        case .refused(let error): error
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
    func nextEvent() throws(ServeFailure) -> TreeEvent?
}

extension TreeReader: TreeEventSource {
    func nextEvent() throws(ServeFailure) -> TreeEvent? {
        do {
            return try next()
        } catch {
            throw .read(error)
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

    func nextEvent() throws(ServeFailure) -> TreeEvent? {
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
