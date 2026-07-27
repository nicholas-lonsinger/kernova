import KernovaKit

// The principal class for the host appex (`NSExtensionPrincipalClass =
// $(PRODUCT_MODULE_NAME).HostFileProviderExtension`). It must stay in this
// module so its runtime name is stable; all logic lives in the shared
// `FileProviderExtension` base in KernovaKit.
final class HostFileProviderExtension: FileProviderExtension {
    override class var directionConfig: FileProviderConfig { .host() }
}
