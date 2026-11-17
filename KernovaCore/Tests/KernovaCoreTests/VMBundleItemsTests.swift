import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("VMBundleItems Tests", .caseScoped)
struct VMBundleItemsTests {
    private let scratch = TestScratchDirectory(prefix: "BundleItemsTests")

    private func write(_ text: String, to path: String) throws -> URL {
        let url = scratch.url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func link(_ path: String, to target: URL) throws {
        let url = scratch.url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    /// What is at each path below `url`: a regular file's text, `nil` for
    /// anything else that is not a directory. The walk follows no link.
    private func tree(at url: URL) throws -> [String: String?] {
        let root = url.path(percentEncoded: false)
        var entries: [String: String?] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: root) {
            let item = url.appendingPathComponent(path)
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true { continue }
            entries[path] =
                values.isRegularFile == true ? String(decoding: try Data(contentsOf: item), as: UTF8.self) : nil
        }
        return entries
    }

    @Test("A tree of files and directories copies whole, hidden files included")
    func treeCopiesWhole() throws {
        _ = try write("plain", to: "Source/Plain")
        _ = try write("hidden", to: "Source/.Hidden")
        _ = try write("nested", to: "Source/Directory/Deeper/Nested")
        let copy = scratch.url.appendingPathComponent("Copy")

        try VMBundleItems.copy(scratch.url.appendingPathComponent("Source"), to: copy)

        #expect(
            try tree(at: copy) == ["Plain": "plain", ".Hidden": "hidden", "Directory/Deeper/Nested": "nested"])
    }

    /// Where a symbolic link sits below the tree being copied, and what it
    /// points at.
    enum LinkCase: String, CaseIterable {
        case fileAtTheTop = "Disk"
        case fileBelow = "Directory/Deeper/Disk"
        case directory = "Directory/Linked"
        case targetGone = "Directory/Gone"
        case ancestor = "Directory/Deeper/Up"
    }

    @Test(
        "A symbolic link anywhere in the tree fails the copy, and the walk finds it, naming the link by its path",
        arguments: LinkCase.allCases)
    func linkFailsTheCopy(_ linkCase: LinkCase) throws {
        _ = try write("plain", to: "Source/Directory/Deeper/Plain")
        let target: URL =
            switch linkCase {
            case .fileAtTheTop, .fileBelow: try write("disk", to: "Elsewhere/Disk")
            case .directory: try write("inner", to: "Elsewhere/Tree/Inner").deletingLastPathComponent()
            case .targetGone: scratch.url.appendingPathComponent("Nowhere")
            case .ancestor: scratch.url.appendingPathComponent("Source")
            }
        try link("Source/\(linkCase.rawValue)", to: target)
        let source = scratch.url.appendingPathComponent("Source")
        let refusal = VMBundleItems.SymbolicLinkError(url: source.appendingPathComponent(linkCase.rawValue))

        #expect(throws: refusal) {
            try VMBundleItems.copy(source, to: scratch.url.appendingPathComponent("Copy"))
        }
        let found = try #require(VMBundleItems.symbolicLink(below: source))
        #expect(found == refusal)
        #expect(
            found.statement(below: source)
                == "\u{201C}\(linkCase.rawValue)\u{201D} is a symbolic link, and Kernova supports only real files and folders inside a virtual machine."
        )
    }

    @Test("A tree with no symbolic link below it has none to find, even reached through a link to it")
    func walkThroughALinkedRootFindsNone() throws {
        _ = try write("plain", to: "Real/Plain")
        _ = try write("hidden", to: "Real/.Hidden")
        _ = try write("nested", to: "Real/Directory/Deeper/Nested")
        let real = scratch.url.appendingPathComponent("Real")
        try link("Alias", to: real)

        #expect(VMBundleItems.symbolicLink(below: real) == nil)
        #expect(VMBundleItems.symbolicLink(below: scratch.url.appendingPathComponent("Alias")) == nil)
    }

    @Test("Copying a symbolic link itself fails, whatever it points at")
    func copyOfALinkFails() throws {
        let file = try write("held", to: "Real/File")
        try link("Alias", to: file.deletingLastPathComponent())
        let alias = scratch.url.appendingPathComponent("Alias")

        #expect(throws: VMBundleItems.SymbolicLinkError(url: alias)) {
            try VMBundleItems.copy(alias, to: scratch.url.appendingPathComponent("Copy"))
        }
    }

    @Test("A directory that denies writing copies whole and keeps its permissions")
    func readOnlyDirectoryCopiesWhole() throws {
        let file = try write("held", to: "Source/Locked/File")
        let locked = file.deletingLastPathComponent().path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        let copy = scratch.url.appendingPathComponent("Copy")

        try VMBundleItems.copy(scratch.url.appendingPathComponent("Source"), to: copy)

        let copied = copy.appendingPathComponent("Locked").path(percentEncoded: false)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copied) }
        #expect(try tree(at: copy) == ["Locked/File": "held"])
        #expect(try FileManager.default.attributesOfItem(atPath: copied)[.posixPermissions] as? Int == 0o555)
    }

    @Test("A named item that is a link whose target is gone fails the copy rather than being left out")
    func danglingNamedItemFails() throws {
        _ = try write("plain", to: "Source/Plain")
        try link("Source/Disk", to: scratch.url.appendingPathComponent("Nowhere"))
        let source = scratch.url.appendingPathComponent("Source")

        #expect(throws: VMBundleItems.SymbolicLinkError(url: source.appendingPathComponent("Disk"))) {
            try VMBundleItems.copyItems(
                ["Disk"], from: source, to: scratch.url.appendingPathComponent("Copy"), ifMissing: .skip)
        }
    }
}
