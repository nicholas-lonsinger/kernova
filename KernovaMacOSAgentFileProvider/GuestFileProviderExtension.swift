import KernovaKit

// The principal class for the guest appex (`NSExtensionPrincipalClass =
// $(PRODUCT_MODULE_NAME).GuestFileProviderExtension`). It must stay in this
// module so its runtime name is stable; all logic lives in the shared
// `FileProviderExtension` base in KernovaKit.
final class GuestFileProviderExtension: FileProviderExtension {
    override class var directionConfig: FileProviderConfig { .guest() }
}
