#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentRuntime
import KernovaPlatformPOSIX
import KernovaSynchronization
import Testing

/// A started stream that reads to the end, calling `readMore()` after every `.received`.
private final class DrainedStream: Sendable {
    let queue = DispatchQueue(label: "app.kernova.tests.posix.drained")
    let stream: POSIXByteStream
    let receivedBytes = Locked(0)
    let ends = Recorder<ByteStreamEvent>()
    let released = Recorder<Int>()

    init(adopting descriptor: Int32) throws {
        let released = released
        stream = try POSIXByteStream(adopting: descriptor) { released.record(1) }
        let (stream, receivedBytes, ends) = (stream, receivedBytes, ends)
        stream.start(on: queue) { event in
            switch event {
            case .received(let data):
                receivedBytes.withLock { $0 += data.count }
                stream.readMore()
            case .ended:
                ends.record(event)
            }
        }
    }

    /// Writes `chunks` from the start queue and waits for the completion.
    func write(_ chunks: [Data]) async -> ByteStreamError? {
        let done = Recorder<ByteStreamError?>()
        queue.async { [stream] in stream.write(chunks) { done.record($0) } }
        var waiter = done.waiter()
        return await waiter.next { _ in true }
    }
}

/// Runs `work` on a queue of its own: a block that blocks in a socket call never holds a thread another stream's
/// queue needs, as a block on a global queue may where the root queue's pool is bounded.
private func onOwnQueue(_ work: @escaping @Sendable () -> Void) {
    DispatchQueue(label: "app.kernova.tests.posix.blocking").async(execute: work)
}

/// Sends `bytes` with the platform's no-SIGPIPE spelling, so a far side the stream shut down fails with `EPIPE`.
private func sendNoSignal(_ descriptor: Int32, _ bytes: [UInt8]) -> Int {
    #if canImport(Darwin)
    bytes.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, 0) }
    #else
    bytes.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
    #endif
}

extension SocketTests {
    @Suite("POSIX byte stream under load")
    struct POSIXByteStreamStressTests {
        @Test(
            "48 streams each move 1 MB both ways over 4 KiB buffers and end with exactly one .eof",
            .timeLimit(.minutes(2)))
        func concurrentBulkTransfers() async throws {
            let size = 1_000_000
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<48 {
                    let (local, far) = try RawSocket.pair(sendBuffer: 4_096)
                    var small: Int32 = 4_096
                    _ = setsockopt(far, SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout<Int32>.size))
                    let drained = try DrainedStream(adopting: local)
                    group.addTask {
                        let farWrote = Recorder<Int>()
                        let farRead = Recorder<Int>()
                        onOwnQueue {
                            RawSocket.send(far, Data(count: size))
                            _ = shutdown(far, Int32(SHUT_WR))
                            farWrote.record(1)
                        }
                        onOwnQueue { farRead.record(RawSocket.read(far, total: size).count) }
                        for _ in 0..<4 {
                            #expect(await drained.write([Data(count: size / 4)]) == nil)
                        }
                        var read = farRead.waiter()
                        #expect(await read.next { _ in true } == size)
                        var wrote = farWrote.waiter()
                        _ = await wrote.next { _ in true }
                        var ends = drained.ends.waiter()
                        #expect(await ends.next { _ in true } == .ended(.eof))
                        #expect(drained.receivedBytes.withLock { $0 } == size)
                        drained.stream.shutdown()
                        var released = drained.released.waiter()
                        _ = await released.next { _ in true }
                        await flush(drained.queue)
                        #expect(drained.ends.elements == [.ended(.eof)])
                        close(far)
                    }
                }
                try await group.waitForAll()
            }
        }

        @Test(
            """
            640 streams with far-side traffic and a pending write, shut down twice from another thread, each \
            deliver one .ended, never EBADF, and release once
            """,
            .timeLimit(.minutes(2)))
        func shutdownChurn() async throws {
            for round in 0..<40 {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for lane in 0..<16 {
                        let (local, far) = try RawSocket.pair(sendBuffer: 4_096)
                        #if canImport(Darwin)
                        var on: Int32 = 1
                        _ = setsockopt(far, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                        #endif
                        let drained = try DrainedStream(adopting: local)
                        group.addTask {
                            // Sends until the stream's shutdown makes a send fail; `far` closes only after.
                            let senderDone = Recorder<Int>()
                            onOwnQueue {
                                let bytes = [UInt8](repeating: 7, count: 512)
                                while sendNoSignal(far, bytes) > 0 {}
                                senderDone.record(1)
                            }
                            // 200 KB into a 4 KiB buffer the far side never reads stays pending.
                            let writeDone = Recorder<ByteStreamError?>()
                            drained.queue.async { [stream = drained.stream] in
                                stream.write([Data(count: 200_000)]) { writeDone.record($0) }
                            }
                            // Varies where the shutdown lands among the reads and the pending write; the test
                            // waits on none of it.
                            let jitter = UInt32((round * 31 + lane * 17) % 400)
                            onOwnQueue {
                                usleep(jitter)
                                drained.stream.shutdown()
                                drained.stream.shutdown()
                            }
                            var released = drained.released.waiter()
                            _ = await released.next { _ in true }
                            var written = writeDone.waiter()
                            let writeError = await written.next { _ in true }
                            #expect(writeError == .shutDown || writeError == nil)
                            var sent = senderDone.waiter()
                            _ = await sent.next { _ in true }
                            close(far)
                            // Anything delivered after the release would already be on the start queue.
                            await flush(drained.queue)
                            let ends = drained.ends.elements
                            #expect(ends.count == 1)
                            #expect(!ends.contains(.ended(.failed(.system(EBADF)))))
                            #expect(drained.released.elements.count == 1)
                        }
                    }
                    try await group.waitForAll()
                }
            }
        }
    }
}
#endif
