import AppKit
import UniformTypeIdentifiers

extension NSOpenPanel {

    /// Presents a pre-configured disk image browser and returns the selected URLs.
    ///
    /// Returns an empty array if the user cancels.
    @MainActor
    static func browseDiskImages(
        message: String,
        allowsMultipleSelection: Bool = false
    ) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.allowedContentTypes = UTType.diskImageTypes
        panel.message = message
        panel.prompt = "Attach"

        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
