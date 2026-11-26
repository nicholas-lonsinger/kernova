import Foundation
import KernovaKit
import KernovaTestSupport
import Testing
import Virtualization

@testable import KernovaCore

/// The names a share can go by, judged by Virtualization's own check of the
/// name a macOS guest mounts a folder by.
@Suite("Shared directory names", .caseScoped)
struct SharedDirectoryNameTests {
    /// Every character Virtualization refuses, the names it reserves, a NUL,
    /// whitespace, a byte-order mark, a control character, a combining mark
    /// and a letter of each UTF-8 length.
    private static let alphabet: [String] = [
        "a", "é", "\u{301}", "中", "😀", " ", "\n", "\u{7F}", "\u{FEFF}", ".", "~", "-", "\u{0}",
        "*", "/", ":", "<", ">", "?", "\\", "|",
    ]

    /// Every string of up to three of ``alphabet``, and names around 255
    /// bytes of UTF-8 built from letters of each length.
    private static let names: [String] = {
        var names = [""]
        var longest = [""]
        for _ in 0..<3 {
            longest = longest.flatMap { name in alphabet.map { name + $0 } }
            names += longest
        }
        for letter in ["a", "é", "中", "😀", "e\u{301}"] {
            for bytes in 250...260 {
                let count = bytes / letter.utf8.count
                names.append(
                    String(repeating: letter, count: count)
                        + String(repeating: "a", count: bytes - count * letter.utf8.count))
            }
        }
        return names
    }()

    /// Read as a configuration file is: two shares storing each name, which
    /// keep it, or take the name it makes, or one counted after it.
    @Test("Every name a share is read under is one Virtualization takes as the name a macOS guest mounts a folder by")
    func everyShareNameIsOneVirtualizationTakes() {
        let refused = Self.names.flatMap { stored in
            NamedList(repairing: [
                SharedDirectory(path: "/Users/Shared/Projects", name: stored),
                SharedDirectory(path: "/Users/Shared/Projects", name: stored),
            ]).map(\.name).filter { (try? VZMultipleDirectoryShare.validateName($0)) == nil }
        }
        #expect(refused.isEmpty, "\(refused.map { $0.unicodeScalars.map { String($0.value, radix: 16) } })")
    }
}
