import AppKit
import Foundation
import Testing
@testable import Kernova

/// Targeted tests for the small helpers in
/// ``BootConfigStepViewController`` that don't require standing up the
/// whole creation wizard.
@Suite("BootConfigStepViewController helpers")
@MainActor
struct BootConfigStepViewControllerTests {
    @Test("fileName returns the last path component for a normal path")
    func fileNameNormalPath() {
        let result = BootConfigStepViewController.fileName("/tmp/some-image.iso")
        #expect(result == "some-image.iso")
    }

    @Test("fileName treats an empty path as 'No file selected'")
    func fileNameEmptyPath() {
        // `URL(fileURLWithPath: "")` resolves to the current working
        // directory, so without the guard the label would render the CWD's
        // basename — confusing for users.
        let result = BootConfigStepViewController.fileName("")
        #expect(result == "No file selected")
    }

    @Test("fileName works for nested paths")
    func fileNameNested() {
        let result = BootConfigStepViewController.fileName("/Users/nl/Downloads/ubuntu-server.iso")
        #expect(result == "ubuntu-server.iso")
    }
}
