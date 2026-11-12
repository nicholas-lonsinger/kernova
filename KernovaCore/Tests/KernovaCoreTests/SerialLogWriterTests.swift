import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("SerialLogWriter", .caseScoped)
struct SerialLogWriterTests {
    private let scratch = TestScratchDirectory(prefix: "SerialLogWriterTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    private func contents(of url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false))
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @Test("A second rotation replaces the previous serial.log.1")
    func secondRotationReplacesPrevious() throws {
        let logURL = scratch.url.appendingPathComponent("serial.log")
        let rotatedURL = scratch.url.appendingPathComponent("serial.log.1")

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
        let logURL = scratch.url.appendingPathComponent("serial.log")
        let rotatedURL = scratch.url.appendingPathComponent("serial.log.1")
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
        let logURL = scratch.url.appendingPathComponent("serial.log")
        let rotatedURL = scratch.url.appendingPathComponent("serial.log.1")
        try Data("old\n".utf8).write(to: logURL)

        let writer = SerialLogWriter(logURL: logURL, rotatedURL: rotatedURL, label: "test", maxFileSize: 1024)
        writer.write(Data("new\n".utf8))
        writer.close()

        #expect(contents(of: logURL) == "old\nnew\n")
        #expect(!FileManager.default.fileExists(atPath: rotatedURL.path(percentEncoded: false)))
    }

    @Test("Writes after close are dropped without error")
    func writeAfterCloseIsDropped() throws {
        let logURL = scratch.url.appendingPathComponent("serial.log")
        let rotatedURL = scratch.url.appendingPathComponent("serial.log.1")

        let writer = SerialLogWriter(logURL: logURL, rotatedURL: rotatedURL, label: "test", maxFileSize: 1024)
        writer.write(Data("kept".utf8))
        writer.close()
        writer.write(Data("dropped".utf8))
        writer.close()

        #expect(contents(of: logURL) == "kept")
    }

    @Test("Empty writes never trigger rotation")
    func emptyWriteIsIgnored() throws {
        let logURL = scratch.url.appendingPathComponent("serial.log")
        let rotatedURL = scratch.url.appendingPathComponent("serial.log.1")

        let writer = SerialLogWriter(logURL: logURL, rotatedURL: rotatedURL, label: "test", maxFileSize: 4)
        writer.write(Data("full".utf8))  // exactly at cap → rotates
        writer.write(Data())  // must not rotate the now-empty live file again
        writer.close()

        #expect(contents(of: rotatedURL) == "full")
        #expect(contents(of: logURL) == "")
    }
}
