import Foundation
import Testing
import Virtualization

@testable import Kernova

@Suite("DiskImageFormatGuidance Tests")
struct DiskImageFormatGuidanceTests {
    private func vzError(_ code: VZError.Code) -> NSError {
        NSError(domain: VZError.errorDomain, code: code.rawValue)
    }

    private var invalidDiskImage: NSError { vzError(.invalidDiskImage) }

    /// The shape of a sandbox-denied open, which shares these code paths.
    private var operationNotSupported: NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
    }

    // MARK: - isInvalidDiskImage

    @Test("Virtualization's invalid-disk-image error is recognized")
    func recognizesInvalidDiskImage() {
        #expect(DiskImageFormatGuidance.isInvalidDiskImage(invalidDiskImage))
    }

    @Test("Other Virtualization errors are not invalid-disk-image")
    func otherVZErrorsRejected() {
        #expect(!DiskImageFormatGuidance.isInvalidDiskImage(vzError(.internalError)))
        #expect(
            !DiskImageFormatGuidance.isInvalidDiskImage(vzError(.invalidVirtualMachineConfiguration))
        )
    }

    @Test("An error from another domain sharing the code is not invalid-disk-image")
    func otherDomainRejected() {
        // Same numeric code, different domain — the domain check is what
        // separates them.
        let posix = NSError(domain: NSPOSIXErrorDomain, code: VZError.Code.invalidDiskImage.rawValue)
        #expect(!DiskImageFormatGuidance.isInvalidDiskImage(posix))
        #expect(!DiskImageFormatGuidance.isInvalidDiskImage(operationNotSupported))
    }

    // MARK: - attachFailureMessage

    @Test("Invalid-disk-image failures explain the format and size requirement")
    func formatMessageForInvalidDiskImage() {
        let message = DiskImageFormatGuidance.attachFailureMessage(
            subject: "storage disk 'Data'", path: "/tmp/data.dmg", underlying: invalidDiskImage)
        #expect(message.contains("storage disk 'Data'"))
        #expect(message.contains("/tmp/data.dmg"))
        #expect(message.contains("512"))
        #expect(message.contains("ASIF"))
        #expect(!message.contains("moved or replaced"))
    }

    @Test("Other attach failures keep the moved-or-permission message")
    func movedMessageForOtherFailures() {
        let message = DiskImageFormatGuidance.attachFailureMessage(
            subject: "removable media 'Installer'", path: "/tmp/x.iso",
            underlying: operationNotSupported)
        #expect(message.contains("removable media 'Installer'"))
        #expect(message.contains("moved or replaced"))
        #expect(message.contains(operationNotSupported.localizedDescription))
        #expect(!message.contains("512"))
    }

    // MARK: - suggestedCommand

    @Test("No command is suggested for failures other than invalid disk image")
    func noCommandForOtherFailures() {
        #expect(
            DiskImageFormatGuidance.suggestedCommand(
                forPath: "/tmp/data.dmg", underlying: operationNotSupported) == nil)
    }

    @Test("The suggested command converts to an ASIF copy beside the source")
    func commandTargetsASIFBesideSource() {
        let command = DiskImageFormatGuidance.suggestedCommand(
            forPath: "/tmp/data.dmg", underlying: invalidDiskImage)
        #expect(
            command == "diskutil image create from --format ASIF '/tmp/data.dmg' '/tmp/data.asif'")
    }

    @Test("An extensionless path still gets an .asif destination")
    func commandForExtensionlessPath() {
        let command = DiskImageFormatGuidance.suggestedCommand(
            forPath: "/tmp/diskimage", underlying: invalidDiskImage)
        #expect(command?.hasSuffix("'/tmp/diskimage' '/tmp/diskimage.asif'") == true)
    }

    @Test("Paths with spaces are quoted for the shell")
    func commandQuotesSpaces() {
        let command = DiskImageFormatGuidance.suggestedCommand(
            forPath: "/tmp/my image.dmg", underlying: invalidDiskImage)
        #expect(command?.hasSuffix("'/tmp/my image.dmg' '/tmp/my image.asif'") == true)
    }

    @Test("A single quote in the path is escaped by closing and reopening the quoted run")
    func commandEscapesSingleQuote() {
        let command = DiskImageFormatGuidance.suggestedCommand(
            forPath: "/tmp/it's.dmg", underlying: invalidDiskImage)
        // '/tmp/it'\''s.dmg' — the shell concatenates the three runs back into
        // /tmp/it's.dmg.
        #expect(command?.contains("'/tmp/it'\\''s.dmg'") == true)
        #expect(command?.hasSuffix("'/tmp/it'\\''s.asif'") == true)
    }
}
