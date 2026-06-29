import KernovaKit

// KernovaClipboardFileProvider — host "Copy to Mac" File Provider extension (#424).
//
// The principal class for the host appex (`NSExtensionPrincipalClass =
// $(PRODUCT_MODULE_NAME).HostFileProviderExtension`). All logic lives in the
// shared `ClipboardFileProviderExtension` base in KernovaKit; this subclass only
// selects the host direction, keeping the principal class in the appex module
// where its runtime name is stable.
//
// The host relay is vended by the SMAppService broker (Phase 2b), not by the
// main app directly — the Phase-0 spike proved a non-sandboxed, non-launchd app
// can't register a Mach service. Until the broker lands, `fetchContents` fails
// cleanly with `serverUnreachable`.
final class HostFileProviderExtension: ClipboardFileProviderExtension {
    override class var directionConfig: ClipboardFileProviderConfig { .host }
}
