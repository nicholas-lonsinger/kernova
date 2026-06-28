import FileProvider
import Foundation
import Testing

@Suite("ClipboardFileProviderHost availability mapping")
struct ClipboardFileProviderHostAvailabilityTests {
    @Test("no error maps to .ready (the user has the extension enabled)")
    func noErrorIsReady() {
        #expect(ClipboardFileProviderHost.availability(from: nil) == .ready)
    }

    @Test("NSFileProviderErrorDomain -2011 maps to .needsEnabling")
    func domainDisabledIsNeedsEnabling() {
        // The literal -2011 locks the hard-coded `domainDisabledCode` against an
        // SDK symbol drift that would silently demote large-file paste to the
        // deadline-prone sync path.
        let error = NSError(domain: NSFileProviderErrorDomain, code: -2011)
        #expect(ClipboardFileProviderHost.availability(from: error) == .needsEnabling)
    }

    @Test("a wrong domain or a different code maps to .unavailable")
    func otherErrorsAreUnavailable() {
        // Right code, wrong domain — proves the domain check matters.
        #expect(
            ClipboardFileProviderHost.availability(
                from: NSError(domain: NSCocoaErrorDomain, code: -2011)) == .unavailable)
        // Right domain, a different File Provider error (serverUnreachable).
        #expect(
            ClipboardFileProviderHost.availability(
                from: NSError(domain: NSFileProviderErrorDomain, code: -1004)) == .unavailable)
    }
}
