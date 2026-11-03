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

/// Lands the far side's items as `ItemSinkEffect` asks: a FILE or FOLDER through a `TreeReceiver` staging beside
/// its landing's directory and publishing under the landing's name, an INLINE representation decoded into memory
/// and published as its bytes. Each pull's work runs on a queue of its own.
public final class ItemSinkAdapter<FileSystem: MutableTreeFileSystem>: ItemSink {
    private enum Pull {
        case tree(TreeReceiver<FileSystem>, PublishName)
        case inline(InlineReceiver)
        /// The sink refused the pull; later bytes are dropped.
        case refused
    }

    private let fileSystem: FileSystem
    private let decodingWorkers: Int
    private let pulls = PullLanes<Pull>(label: "app.kernova.item-sink")

    /// A sink landing through `fileSystem`, decompressing LZ4 chunks on `decodingWorkers` lanes per pull.
    ///
    /// - Parameters:
    ///   - fileSystem: The calls a landing makes.
    ///   - decodingWorkers: The lanes each pull decompresses on; by default `TransferCompression`'s count for
    ///     this machine's active cores.
    public init(
        fileSystem: FileSystem,
        decodingWorkers: Int = TransferCompression.decodingWorkers(
            receivingCores: ProcessInfo.processInfo.activeProcessorCount)
    ) {
        self.fileSystem = fileSystem
        self.decodingWorkers = decodingWorkers
    }

    /// The pull of representation `representation` of item `item` of the far side's offer `token`, to land as
    /// `landing` says: it decodes every codec this sink does, and lands compressed the decmpfs types the
    /// volume holding a tree landing's directory reads back (`DecmpfsMatrix.acceptedTypes`).
    ///
    /// - Throws: `WireError` `WRITE_FAILED` when the landing's directory cannot be opened or its volume asked.
    public func request(
        token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding
    ) throws(WireError) -> PullRequest {
        var request = PullRequest()
        request.token = token
        request.item = item
        request.representation = representation
        request.byteCeiling = byteCeiling
        request.codecs = [.lz4]
        guard case .tree(let directory, _) = landing else { return request }
        do {
            let opened = try fileSystem.openDirectory(Array(directory.utf8), in: AT_FDCWD)
            defer { fileSystem.close(opened) }
            request.decmpfsTypes = try DecmpfsMatrix.acceptedTypes(landingIn: opened, on: fileSystem).sorted()
        } catch {
            throw WireError(.writeFailed, posixErrno: error.code, debugDetail: "the landing's directory: \(error)")
        }
        return request
    }

    /// Carries out `effect` on its pull's queue, reporting through `reporter`.
    public func handle(_ effect: ItemSinkEffect, reporter: ItemSinkReporter) {
        switch effect {
        case .begin(let id, let request, let representation, let landing):
            let acceptance = ContainerAcceptance(request, storage: representation.storage)
            pulls.open(id) { [fileSystem, decodingWorkers] in
                switch Self.begin(acceptance, landing, fileSystem: fileSystem, decodingWorkers: decodingWorkers) {
                case .success(let pull):
                    return pull
                case .failure(let error):
                    reporter.report(.refused(id, error))
                    return .refused
                }
            }
        case .bytes(let id, let bytes):
            pulls.run(id) { pull in
                do throws(WireError) {
                    switch pull {
                    case .tree(let receiver, _):
                        try Self.wire { () throws(TreeWriteFailure) in try receiver.receive(bytes) }
                    case .inline(var receiver):
                        // Its bytes then have one owner, so appending to them never copies them.
                        pull = .refused
                        try receiver.receive(bytes)
                        pull = .inline(receiver)
                    case .refused: return
                    }
                    reporter.report(.consumed(id, bytes.count))
                } catch {
                    pull = .refused
                    reporter.report(.refused(id, error))
                }
            }
        case .finish(let id):
            pulls.run(id) { pull in
                do throws(WireError) {
                    switch pull {
                    case .tree(let receiver, _): try Self.wire { () throws(TreeWriteFailure) in try receiver.finish() }
                    case .inline(var receiver):
                        // Its bytes then have one owner, so appending to them never copies them.
                        pull = .refused
                        try receiver.finish()
                        pull = .inline(receiver)
                    case .refused: return
                    }
                    reporter.report(.verified(id))
                } catch {
                    pull = .refused
                    reporter.report(.refused(id, error))
                }
            }
        case .commit(let id):
            pulls.close(id) { pull in
                switch pull {
                case .tree(let receiver, let name):
                    do throws(WireError) {
                        let landed = try Self.wire { () throws(TreeWriteFailure) in try receiver.publish(as: name) }
                        reporter.report(.published(id, .named(Data(landed))))
                    } catch {
                        reporter.report(.publishFailed(id, error))
                    }
                case .inline(let receiver):
                    reporter.report(.published(id, .inline(receiver.bytes)))
                case .refused, nil:
                    reporter.report(
                        .publishFailed(id, WireError(.internal, debugDetail: "a commit of a pull the sink refused")))
                }
            }
        case .abort(let id):
            // Dropping a tree's receiver removes everything it staged.
            pulls.close(id)
        }
    }

    /// A pull's landing, or why it cannot begin.
    private static func begin(
        _ acceptance: ContainerAcceptance, _ landing: ItemLanding, fileSystem: FileSystem, decodingWorkers: Int
    ) -> Result<Pull, WireError> {
        switch landing {
        case .inline:
            return .success(.inline(InlineReceiver(accepting: acceptance)))
        case .tree(let directory, let name):
            let path = Array(directory.utf8)
            do {
                let destination = try fileSystem.openDirectory(path, in: AT_FDCWD)
                let receiver = TreeReceiver(
                    accepting: acceptance, decodingWorkers: decodingWorkers, fileSystem: fileSystem,
                    destination: destination, destinationPathByteCount: path.count)
                return .success(.tree(receiver, PublishName(name)))
            } catch {
                return .failure(
                    WireError(.writeFailed, posixErrno: error.code, debugDetail: "the landing's directory: \(error)"))
            }
        }
    }

    /// Runs `body`, throwing its failure as the error a pull ends with.
    private static func wire<Result>(_ body: () throws(TreeWriteFailure) -> Result) throws(WireError) -> Result {
        do {
            return try body()
        } catch {
            throw WireError(received: error.wireError)
        }
    }
}

extension PublishName {
    /// The receiver's form of a landing's name.
    init(_ name: ItemLandingName) {
        switch name {
        case .exactly(let name): self = .exactly(Array(name))
        case .keepingBoth(let name): self = .keepingBoth(Array(name))
        }
    }
}

/// An INLINE representation's container decoded into the bytes of its one DATA entry, held to its acceptance's
/// byte ceiling by the decoder.
struct InlineReceiver {
    private var decoder: ContainerDecoder
    private let acceptance: ContainerAcceptance
    /// The DATA entry's bytes so far.
    private(set) var bytes = Data()

    init(accepting acceptance: ContainerAcceptance) {
        decoder = ContainerDecoder(accepting: acceptance)
        self.acceptance = acceptance
    }

    /// Takes the container's next bytes.
    mutating func receive(_ data: Data) throws(WireError) {
        decoder.feed(data)
        try drain()
    }

    /// Confirms the container ended whole.
    mutating func finish() throws(WireError) {
        try drain()
        do {
            try decoder.finish()
        } catch {
            throw error.wireError(acceptance)
        }
    }

    private mutating func drain() throws(WireError) {
        do {
            while let event = try decoder.next() {
                switch event {
                case .bytes(let data): bytes.append(data)
                case .zeros(let count): bytes.append(Data(count: Int(count)))
                default: break
                }
            }
        } catch {
            throw error.wireError(acceptance)
        }
    }
}

extension ContainerError {
    /// The error a pull ends with for this refusal under `acceptance`.
    func wireError(_ acceptance: ContainerAcceptance) -> WireError {
        WireError(
            errorCode, limit: errorCode == .tooLarge ? acceptance.byteCeiling : 0, debugDetail: "\(self)")
    }
}
#endif
