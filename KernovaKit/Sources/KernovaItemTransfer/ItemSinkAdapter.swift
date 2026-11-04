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
import KernovaSynchronization
import KernovaTreeTransfer
import KernovaWire

/// Lands the far side's items as `ItemSinkEffect` asks: each representation, INLINE as much as FILE or FOLDER,
/// through a `TreeReceiver` staging beside its landing's directory and publishing under the landing's name, its
/// landed bytes charged to the order's budget when it has one. Each pull's work runs on a queue of its own.
public final class ItemSinkAdapter<FileSystem: MutableTreeFileSystem>: ItemSink {
    private enum Pull {
        case receiving(TreeReceiver<FileSystem>)
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
    /// `landing` says, its landed bytes charged to `budget` beside `byteCeiling`: it decodes every codec this
    /// sink does, and lands compressed the decmpfs types the volume holding the landing's directory reads back
    /// (`DecmpfsMatrix.acceptedTypes`).
    ///
    /// - Throws: `WireError` `WRITE_FAILED` when the landing's directory cannot be opened or its volume asked.
    public func order(
        token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding,
        budget: ByteBudget? = nil
    ) throws(WireError) -> ItemPullOrder {
        var request = PullRequest()
        request.token = token
        request.item = item
        request.representation = representation
        request.byteCeiling = byteCeiling
        request.codecs = [.lz4]
        do {
            let opened = try fileSystem.openDirectory(Array(landing.directory.utf8), in: AT_FDCWD)
            defer { fileSystem.close(opened) }
            request.decmpfsTypes = try DecmpfsMatrix.acceptedTypes(landingIn: opened, on: fileSystem).sorted()
        } catch {
            throw WireError(.writeFailed, posixErrno: error.code, debugDetail: "the landing's directory: \(error)")
        }
        return ItemPullOrder(request, landing: landing, budget: budget)
    }

    /// Carries out `effect` on its pull's queue, reporting through `reporter`.
    public func handle(_ effect: ItemSinkEffect, reporter: ItemSinkReporter) {
        switch effect {
        case .begin(let id, let order, let representation):
            let acceptance = ContainerAcceptance(order.request, storage: representation.storage)
            pulls.open(PullKey(connection: reporter.connection, id: id)) { [fileSystem, decodingWorkers] in
                switch Self.begin(acceptance, order, fileSystem: fileSystem, decodingWorkers: decodingWorkers) {
                case .success(let receiver):
                    return .receiving(receiver)
                case .failure(let error):
                    reporter.report(.refused(id, error))
                    return .refused
                }
            }
        case .bytes(let id, let bytes):
            pulls.run(PullKey(connection: reporter.connection, id: id)) { pull in
                guard case .receiving(let receiver) = pull else { return }
                do throws(WireError) {
                    try Self.wire { () throws(TreeWriteFailure) in try receiver.receive(bytes) }
                    reporter.report(.consumed(id, bytes.count))
                } catch {
                    pull = .refused
                    reporter.report(.refused(id, error))
                }
            }
        case .finish(let id):
            pulls.run(PullKey(connection: reporter.connection, id: id)) { pull in
                guard case .receiving(let receiver) = pull else { return }
                do throws(WireError) {
                    try Self.wire { () throws(TreeWriteFailure) in try receiver.finish() }
                    reporter.report(.verified(id))
                } catch {
                    pull = .refused
                    reporter.report(.refused(id, error))
                }
            }
        case .commit(let id):
            pulls.close(PullKey(connection: reporter.connection, id: id)) { pull in
                guard case .receiving(let receiver) = pull else {
                    return reporter.report(
                        .publishFailed(id, WireError(.internal, debugDetail: "a commit of a pull the sink refused")))
                }
                do throws(WireError) {
                    let landed = try Self.wire { () throws(TreeWriteFailure) in try receiver.publish() }
                    reporter.report(.published(id, .named(Data(landed))))
                } catch {
                    reporter.report(.publishFailed(id, error))
                }
            }
        case .abort(let id):
            // Dropping a receiver removes everything it staged, and gives back what it charged.
            pulls.close(PullKey(connection: reporter.connection, id: id))
        }
    }

    /// A pull's receiver, or why it cannot begin.
    private static func begin(
        _ acceptance: ContainerAcceptance, _ order: ItemPullOrder, fileSystem: FileSystem, decodingWorkers: Int
    ) -> Result<TreeReceiver<FileSystem>, WireError> {
        let path = Array(order.landing.directory.utf8)
        do {
            let destination = try fileSystem.openDirectory(path, in: AT_FDCWD)
            return .success(
                TreeReceiver(
                    name: PublishName(order.landing.name), accepting: acceptance, decodingWorkers: decodingWorkers,
                    fileSystem: fileSystem, destination: destination, destinationPathByteCount: path.count,
                    budget: order.budget))
        } catch {
            return .failure(
                WireError(.writeFailed, posixErrno: error.code, debugDetail: "the landing's directory: \(error)"))
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

extension ContainerError {
    /// The error a pull ends with for this refusal under `acceptance`.
    func wireError(_ acceptance: ContainerAcceptance) -> WireError {
        WireError(
            errorCode, limit: errorCode == .tooLarge ? acceptance.byteCeiling : 0, debugDetail: "\(self)")
    }
}
#endif
