import Foundation

/// Flat RTFD — a serialized file wrapper holding `TXT.rtf` and one attachment —
/// showing the attachment `attachment.png`.
///
/// The attachment is `contents` as a regular file, or, with `linkingTo`, a
/// symbolic link to that file, nested `depth` directories below the root.
public func flatRTFD(
    attachment contents: Data = Data([0x89, 0x50, 0x4E, 0x47]), linkingTo destination: URL? = nil,
    depth: Int = 0
) throws -> Data {
    let path = (0..<depth).map { "d\($0)/" }.joined() + "attachment.png"
    let rtf = "{\\rtf1\\ansi A{{\\NeXTGraphic \(path) \\width140 \\height100}\u{00AC}}B}"
    let text = FileWrapper(regularFileWithContents: Data(rtf.utf8))
    text.preferredFilename = "TXT.rtf"
    var leaf =
        destination.map(FileWrapper.init(symbolicLinkWithDestinationURL:))
        ?? FileWrapper(regularFileWithContents: contents)
    leaf.preferredFilename = "attachment.png"
    for level in (0..<depth).reversed() {
        let directory = FileWrapper(directoryWithFileWrappers: [:])
        directory.preferredFilename = "d\(level)"
        directory.addFileWrapper(leaf)
        leaf = directory
    }
    let root = FileWrapper(directoryWithFileWrappers: [:])
    root.addFileWrapper(text)
    root.addFileWrapper(leaf)
    guard let data = root.serializedRepresentation else { throw CocoaError(.fileWriteUnknown) }
    return data
}
