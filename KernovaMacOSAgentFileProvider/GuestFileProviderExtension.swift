import KernovaKit

// KernovaMacOSAgentFileProvider — guest File Provider extension (issue #376).
//
// The principal class for the guest appex (`NSExtensionPrincipalClass =
// $(PRODUCT_MODULE_NAME).GuestFileProviderExtension`). All logic lives in the
// shared `FileProviderExtension` base in KernovaKit; this subclass only selects
// the guest direction, keeping the principal class in the appex module where its
// runtime name is stable.
final class GuestFileProviderExtension: FileProviderExtension {
    override class var directionConfig: FileProviderConfig { .guest() }
}
