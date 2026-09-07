import Foundation

/// A virtual machine's bundle as a file, for everything that has to name one
/// without opening it.
public enum VMBundleFormat {
    /// The extension every virtual machine bundle carries.
    ///
    /// In this package rather than beside the store that writes the bundles,
    /// because the `kernova` tool names the same file type when it offers a
    /// path to import and reaches nothing in the app.
    public static let fileExtension = "kernova"
}
