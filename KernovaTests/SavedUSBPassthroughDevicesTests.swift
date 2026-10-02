import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// The record of what a saved state holds goes wherever the save file goes,
/// and a save holding nothing carries none.
@Suite("SavedUSBPassthroughDevices Tests", .caseScoped)
@MainActor
struct SavedUSBPassthroughDevicesTests {
    private let scratch = TestScratchDirectory(prefix: "SavedUSBPassthroughDevicesTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    private func saveFile(_ name: String, contents: String = "saved state") throws -> URL {
        let url = scratch.url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private let held = [
        AttachedUSBAccessory(
            deviceID: UUID(), accessory: MockUSBAccessoryService.accessory(registryID: 1, serial: "0373"))
    ]

    @Test("A save file with no record holds no device")
    func noRecordIsNoDevices() throws {
        #expect(SavedUSBPassthroughDevices.devices(onSaveFileAt: try saveFile("Save")).isEmpty)
    }

    @Test("A copy of the save file carries its record")
    func aCopyCarriesTheRecord() throws {
        let original = try saveFile("Save")
        try SavedUSBPassthroughDevices.record(held, onSaveFileAt: original)
        let copy = scratch.url.appendingPathComponent("Copy")

        try FileManager.default.copyItem(at: original, to: copy)

        #expect(
            SavedUSBPassthroughDevices.devices(onSaveFileAt: copy).map(\.deviceID)
                == held.map(\.deviceID))
    }

    @Test("Recording no devices removes the record an earlier state left")
    func anEmptyRecordRemovesAnEarlierOne() throws {
        let url = try saveFile("Save")
        try SavedUSBPassthroughDevices.record(held, onSaveFileAt: url)

        try SavedUSBPassthroughDevices.record([], onSaveFileAt: url)

        #expect(SavedUSBPassthroughDevices.devices(onSaveFileAt: url).isEmpty)
    }

    @Test("Recording no devices on a save file that carries none succeeds")
    func anEmptyRecordOnABareFileSucceeds() throws {
        let url = try saveFile("Save")

        try SavedUSBPassthroughDevices.record([], onSaveFileAt: url)

        #expect(SavedUSBPassthroughDevices.devices(onSaveFileAt: url).isEmpty)
    }
}
