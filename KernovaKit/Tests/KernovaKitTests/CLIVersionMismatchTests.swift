import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// An app and a tool speaking different command versions, as the tool meets
/// it on a real socket: the version answer arrives whichever side is older,
/// before anything in the frame past its version is read.
@Suite("CLI version mismatch", .caseScoped)
struct CLIVersionMismatchTests {
    private let current = VMCommandRequest.currentProtocolVersion

    /// Sends a verb to a double answering with the raw `frame`, and hands back
    /// what the tool threw.
    private func failure(answering frame: Data) throws -> CLIFailure? {
        let listener = try TestCommandSocket()
        defer { listener.close() }
        let client = try VMCommandClient(socketPath: listener.path)
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)
        listener.serveFrames([[frame]])

        do {
            let answer = try client.send(.groups)
            Issue.record("The tool read an answer in another vocabulary: \(answer)")
            return nil
        } catch let failure as CLIFailure {
            return failure
        }
    }

    private func failure(answering response: VMCommandResponse) throws -> CLIFailure? {
        try failure(answering: try JSONEncoder().encode(response))
    }

    @Test("An older app that cannot decode the verb answers with the version mismatch, not the decode failure")
    func olderAppThatCannotDecodeTheVerb() throws {
        let thrown = try failure(
            answering: VMCommandResponse(
                result: .refused(.undecodableRequest("The data isn\u{2019}t in the correct format.")),
                protocolVersion: current - 1))

        #expect(thrown == VMCommandResponse.versionMismatch(tool: current, app: current - 1))
        #expect(thrown?.code == .unavailable)
        #expect(
            thrown?.message
                == "This kernova tool uses command version \(current), which doesn\u{2019}t match the running "
                + "Kernova app\u{2019}s version \(current - 1). Quit Kernova and open it again.")
    }

    @Test("An older app that refuses the version yields the version mismatch")
    func olderAppThatRefusesTheVersion() throws {
        let thrown = try failure(
            answering: VMCommandResponse(
                result: .refused(.unsupportedProtocolVersion(peer: current, expected: current - 1)),
                protocolVersion: current - 1))

        #expect(thrown == VMCommandResponse.versionMismatch(tool: current, app: current - 1))
    }

    @Test("A newer app's answer this tool cannot spell yields the version mismatch")
    func newerAppWithAnUnknownResult() throws {
        let frame = Data(#"{"protocolVersion":\#(current + 1),"result":{"aResultFromTheFuture":{}}}"#.utf8)

        let thrown = try failure(answering: frame)

        #expect(thrown == VMCommandResponse.versionMismatch(tool: current, app: current + 1))
        #expect(thrown?.code == .unavailable)
        #expect(
            thrown?.message
                == "This kernova tool uses command version \(current), which doesn\u{2019}t match the running "
                + "Kernova app\u{2019}s version \(current + 1). Quit Kernova and open it again.")
    }

    @Test("A newer app's version refusal yields the version mismatch")
    func newerAppThatRefusesTheVersion() throws {
        let thrown = try failure(
            answering: VMCommandResponse(
                result: .refused(.unsupportedProtocolVersion(peer: current, expected: current + 1)),
                protocolVersion: current + 1))

        #expect(thrown == VMCommandResponse.versionMismatch(tool: current, app: current + 1))
    }

    @Test("The version refusal names the tool's version as the tool's and the app's as the app's")
    func refusalPayloadKeepsEachSidesVersion() {
        let response = VMCommandResponse(
            result: .refused(.unsupportedProtocolVersion(peer: 4, expected: 7)))

        #expect(throws: VMCommandResponse.versionMismatch(tool: 4, app: 7)) {
            try response.payload()
        }
        #expect(
            VMCommandResponse.versionMismatch(tool: 4, app: 7).message
                == "This kernova tool uses command version 4, which doesn\u{2019}t match the running "
                + "Kernova app\u{2019}s version 7. Quit Kernova and open it again.")
    }
}
