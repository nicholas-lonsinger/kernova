import Foundation
import Testing

@testable import Kernova

@Suite("SerialLogWriter")
struct SerialLogWriterTests {
    private func makeTempDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func contents(of url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false))
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @Test("Writes append to the log file")
    func writesAppend() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logURL = tempDir.appendingPathComponent("serial.log")
        let rotatedURL = tempDir.appendingPathComponent("serial.log.1")

        let writer = SerialLogWriter(logURL: logURL, rotatedURL: rotatedURL, label: "test", maxFileSize: 1024)
        writer.write(Data("hello ".utf8))
        writer.write(Data("world".utf8))
        writer.close()

        #expect(contents(of: logURL) == "hello world")
    }

    @Test("A new writer appends to an existing log")
    func newWriterAppends() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logURL = tempDir.appendingPathComponent("serial.log")
        let rotatedURL = tempDir.appendingPathComponent("serial.log.1")

        let first = SerialLogWriter(logURL: logURL, rotatedURL: rotatedURL, label: "test", maxFileSize: 1024)
        first.write(Data("run1\n".utf8))
        first.close()

        let second = SerialLogWriter(logURL: logURL, rotatedURL: rotatedURL, label: "test", maxFileSize: 1024)
        second.write(Data("run2\n".utf8))
        second.close()

        #expect(contents(of: logURL) == "run1\nrun2\n")
    }

    @Test("Reaching the cap rotates the log to serial.log.1 and starts fresh")
    func rotationAtCap() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logURL = tempDir.appendingPathComponent("serial.log")
        let rotatedURL = tempDir.appendingPathComponent("serial.log.1")

        let writer = SerialLogWriter(logURL: logURL, rotatedURL: rotatedURL, label: "test", maxFileSize: 8)
        writer.write(Data("0123456789".utf8))  // 10 bytes ≥ cap → rotates
        writer.write(Data("after".utf8))
        writer.close()

        #expect(contents(of: rotatedURL) == "0123456789")
        #expect(contents(of: logURL) == "after")
    }

    @Test("A second rotation replaces the previous serial.log.1")
    func secondRotationReplacesPrevious() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logURL = tempDir.appendingPathComponent("serial.log")
        let rotatedURL = tempDir.appendingPathComponent("serial.log.1")

        let writer = SerialLogWriter(logURL: logURL, rotatedURL: rotatedURL, label: "test", maxFileSize: 8)
        writer.write(Data("first-gen".utf8))  // rotation 1
        writer.write(Data("second-gen".utf8))  // rotation 2
        writer.write(Data("live".utf8))
        writer.close()

        #expect(contents(of: rotatedURL) == "second-gen")
        #expect(contents(of: logURL) == "live")
    }

    @Test("An oversized pre-existing log is cleared on open, not archived")
    func oversizedExistingLogIsClearedOnOpen() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logURL = tempDir.appendingPathComponent("serial.log")
        let rotatedURL = tempDir.appendingPathComponent("serial.log.1")
        try Data("stale-history".utf8).write(to: logURL)
        try Data("prior-generation".utf8).write(to: rotatedURL)

        let writer = SerialLogWriter(logURL: logURL, rotatedURL: rotatedURL, label: "test", maxFileSize: 8)
        writer.write(Data("fresh".utf8))
        writer.close()

        #expect(contents(of: logURL) == "fresh")
        #expect(contents(of: rotatedURL) == "prior-generation")
    }

    @Test("An under-cap pre-existing log is kept and appended to")
    func underCapExistingLogIsKept() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logURL = tempDir.appendingPathComponent("serial.log")
        let rotatedURL = tempDir.appendingPathComponent("serial.log.1")
        try Data("old\n".utf8).write(to: logURL)

        let writer = SerialLogWriter(logURL: logURL, rotatedURL: rotatedURL, label: "test", maxFileSize: 1024)
        writer.write(Data("new\n".utf8))
        writer.close()

        #expect(contents(of: logURL) == "old\nnew\n")
        #expect(!FileManager.default.fileExists(atPath: rotatedURL.path(percentEncoded: false)))
    }

    @Test("Writes after close are dropped without error")
    func writeAfterCloseIsDropped() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logURL = tempDir.appendingPathComponent("serial.log")
        let rotatedURL = tempDir.appendingPathComponent("serial.log.1")

        let writer = SerialLogWriter(logURL: logURL, rotatedURL: rotatedURL, label: "test", maxFileSize: 1024)
        writer.write(Data("kept".utf8))
        writer.close()
        writer.write(Data("dropped".utf8))
        writer.close()

        #expect(contents(of: logURL) == "kept")
    }

    @Test("A failed open drops writes without crashing")
    func failedOpenDropsWrites() {
        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = missingDir.appendingPathComponent("serial.log")
        let rotatedURL = missingDir.appendingPathComponent("serial.log.1")

        let writer = SerialLogWriter(logURL: logURL, rotatedURL: rotatedURL, label: "test", maxFileSize: 1024)
        writer.write(Data("dropped".utf8))
        writer.close()

        #expect(!FileManager.default.fileExists(atPath: logURL.path(percentEncoded: false)))
    }

    @Test("Empty writes never trigger rotation")
    func emptyWriteIsIgnored() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logURL = tempDir.appendingPathComponent("serial.log")
        let rotatedURL = tempDir.appendingPathComponent("serial.log.1")

        let writer = SerialLogWriter(logURL: logURL, rotatedURL: rotatedURL, label: "test", maxFileSize: 4)
        writer.write(Data("full".utf8))  // exactly at cap → rotates
        writer.write(Data())  // must not rotate the now-empty live file again
        writer.close()

        #expect(contents(of: rotatedURL) == "full")
        #expect(contents(of: logURL) == "")
    }
}
