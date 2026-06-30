import FileProvider
import Foundation
import Testing

@testable import KernovaKit

@Suite("ClipboardFileProviderDomainHost availability mapping")
struct ClipboardFileProviderDomainHostAvailabilityTests {
    @Test("userEnabled == true maps to .ready")
    func userEnabledIsReady() {
        #expect(ClipboardFileProviderDomainHost.availability(userEnabled: true) == .ready)
    }

    @Test("userEnabled == false maps to .needsEnabling (the System-Settings toggle is off)")
    func userDisabledIsNeedsEnabling() {
        // Locks the authoritative mapping: a registered-but-disabled domain must
        // route paste to the size-capped sync fallback, not publish a placeholder
        // the disabled extension can never materialize.
        #expect(ClipboardFileProviderDomainHost.availability(userEnabled: false) == .needsEnabling)
    }

    @Test("a lookup error maps to .unavailable")
    func lookupErrorIsUnavailable() {
        let error = NSError(domain: NSFileProviderErrorDomain, code: -1004)
        #expect(
            ClipboardFileProviderDomainHost.availability(
                forDomainMatching: NSFileProviderDomainIdentifier("any"), in: [], error: error)
                == .unavailable)
    }

    @Test("a missing domain maps to .unavailable")
    func missingDomainIsUnavailable() {
        let other = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier("other"), displayName: "Other")
        #expect(
            ClipboardFileProviderDomainHost.availability(
                forDomainMatching: NSFileProviderDomainIdentifier("wanted"), in: [other], error: nil)
                == .unavailable)
    }

    @Test("a matching domain delegates to its userEnabled flag")
    func matchingDomainDelegatesToUserEnabled() {
        // `userEnabled` is read-only, so we can't force a value on a constructed
        // domain — assert the lookup finds the match and routes through the
        // userEnabled mapping (proving identity matching + delegation), rather
        // than pinning a specific default.
        let identifier = NSFileProviderDomainIdentifier("matched")
        let domain = NSFileProviderDomain(identifier: identifier, displayName: "Matched")
        #expect(
            ClipboardFileProviderDomainHost.availability(
                forDomainMatching: identifier, in: [domain], error: nil)
                == ClipboardFileProviderDomainHost.availability(userEnabled: domain.userEnabled))
    }
}
