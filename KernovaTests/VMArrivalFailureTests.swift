import Foundation
import Testing

@testable import Kernova

/// How a create, clone or import failure is worded: the file it failed on is
/// named by the bundle the user knows, never by the staged path under the
/// hidden staging directory.
@Suite("VMArrival failure wording", .caseScoped)
struct VMArrivalFailureTests {
    private let stagingRoot = URL(fileURLWithPath: "/Lib/VMs/.Staging/1234", isDirectory: true)
    private var staged: URL {
        stagingRoot.appendingPathComponent("8E8EE351-CA0A-49C5-A0FC-005740C94921.kernova")
    }
    private let source = VMArrival.Source.importing(
        URL(fileURLWithPath: "/Users/me/Desktop/Mac.kernova", isDirectory: true))

    /// The error `FileManager.copyItem` throws for an unreadable source file,
    /// with the keys a real one carries.
    private func copyError(
        file: String, posix: POSIXErrorCode, failingPath: URL? = nil
    ) -> NSError {
        let from = failingPath ?? source.bundleURL.appendingPathComponent(file)
        let to = staged.appendingPathComponent(file)
        return NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
            userInfo: [
                NSFilePathErrorKey: from.path(percentEncoded: false),
                "NSSourceFilePathErrorKey": from.path(percentEncoded: false),
                "NSDestinationFilePath": to.path(percentEncoded: false),
                NSURLErrorKey: from,
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(posix.rawValue)),
            ])
    }

    private func message(_ error: any Error, kind: VMArrival.Kind = .importing, source: VMArrival.Source?)
        -> String
    {
        VMArrival.failureMessage(
            for: error, kind: kind, name: "Mac", stagedURL: staged, source: source)
    }

    @Test("An unreadable source file is named in the source bundle, with the system's reason")
    func unreadableSourceFileIsNamedInTheSource() {
        let text = message(copyError(file: "Disk.asif", posix: .EACCES), source: source)

        #expect(
            text
                == "\u{201C}Disk.asif\u{201D} in \u{201C}/Users/me/Desktop/Mac.kernova\u{201D} could not be copied: Permission denied."
        )
        #expect(!text.contains(staged.lastPathComponent))
        #expect(!text.contains(".Staging"))
    }

    @Test("A clone's source file is named in the VM it copies")
    func cloneSourceFileIsNamedInTheSourceVM() {
        let vm = VMArrival.Source(
            bundleURL: URL(fileURLWithPath: "/Lib/VMs/AAAA.kernova", isDirectory: true),
            label: "Source")
        let error = copyError(
            file: "Disk.asif", posix: .EACCES,
            failingPath: vm.bundleURL.appendingPathComponent("Disk.asif"))

        #expect(
            message(error, kind: .cloning, source: vm)
                == "\u{201C}Disk.asif\u{201D} in \u{201C}Source\u{201D} could not be copied: Permission denied."
        )
    }

    @Test("A failure on a file being written is named in the VM being made")
    func writtenFileIsNamedInTheNewVM() {
        let error = NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
            userInfo: [
                NSFilePathErrorKey: staged.appendingPathComponent("host-state.json")
                    .path(percentEncoded: false),
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOSPC.rawValue)),
            ])

        let text = message(error, source: source)

        #expect(
            text
                == "\u{201C}host-state.json\u{201D} could not be written into \u{201C}Mac\u{201D}: No space left on device."
        )
        #expect(!text.contains(staged.lastPathComponent))
    }

    @Test(
        "A failure naming only the staging directory states its reason and no path",
        arguments: [
            "/Lib/VMs/.Staging/1234", "/Lib/VMs/.Staging", "/Lib/VMs/.Staging/.1234",
        ])
    func stagingOnlyFailureNamesNoPath(path: String) {
        let error = NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
            userInfo: [
                NSFilePathErrorKey: path,
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue)),
            ])

        #expect(message(error, source: source) == "Permission denied.")
    }

    @Test("A failure on a path the user can see names it")
    func visiblePathIsNamed() {
        let error = NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
            userInfo: [
                NSFilePathErrorKey: "/Lib/VMs",
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue)),
            ])

        #expect(
            message(error, source: source)
                == "\u{201C}/Lib/VMs\u{201D} could not be accessed: Permission denied.")
    }

    @Test("A file error with no system reason names the file and stops")
    func fileErrorWithoutReasonNamesTheFile() {
        let error = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
            userInfo: [
                NSFilePathErrorKey: source.bundleURL.appendingPathComponent("config.json")
                    .path(percentEncoded: false)
            ])

        #expect(
            message(error, source: source)
                == "\u{201C}config.json\u{201D} in \u{201C}/Users/me/Desktop/Mac.kernova\u{201D} could not be copied."
        )
    }

    @Test("An error naming no file keeps its own description")
    func errorWithoutPathKeepsItsDescription() {
        let error = CocoaError(.fileWriteOutOfSpace)

        #expect(message(error, source: nil) == error.localizedDescription)
    }
}
