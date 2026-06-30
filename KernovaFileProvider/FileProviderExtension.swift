import KernovaKit

// KernovaFileProvider — guest File Provider extension (issue #376).
//
// The principal class for the guest appex (`NSExtensionPrincipalClass =
// $(PRODUCT_MODULE_NAME).FileProviderExtension`). All logic lives in the shared
// `ClipboardFileProviderExtension` base in KernovaKit; this subclass only
// selects the guest direction, keeping the principal class in the appex module
// where its runtime name is stable.
final class FileProviderExtension: ClipboardFileProviderExtension {
    override class var directionConfig: ClipboardFileProviderConfig { .guest }
}
