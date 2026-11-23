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
}
