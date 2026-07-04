import KernovaKit

// KernovaClipboardFileProvider — host "Copy to Mac" File Provider extension
// (#424 / #460 servicing migration).
//
// The principal class for the host appex (`NSExtensionPrincipalClass =
// $(PRODUCT_MODULE_NAME).HostFileProviderExtension`). All logic lives in the
// shared `ClipboardFileProviderExtension` base in KernovaKit; this subclass only
// selects the host direction, keeping the principal class in the appex module
// where its runtime name is stable.
//
// The main app reaches this extension through the canonical
// `NSFileProviderServicing` anonymous-XPC pipe (#460): the base vends a service
// source the app connects to and exports the relay on, so the extension calls
// the app back at `fetchContents`. No Mach service and no broker are involved.
final class HostFileProviderExtension: ClipboardFileProviderExtension {
    override class var directionConfig: ClipboardFileProviderConfig { .host }
}
