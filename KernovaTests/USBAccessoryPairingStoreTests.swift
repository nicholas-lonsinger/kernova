import Foundation
import Testing

@testable import Kernova

/// The `usb-accessories.json` file: what a round trip preserves, and what a
/// bundle that cannot answer reads as.
@Suite("USB Accessory Pairing Store Tests", .admissionGated)
struct USBAccessoryPairingStoreTests {
    private let store = USBAccessoryPairingStore()

    /// A bundle directory of this test's own, removed when it finishes.
    private func withBundle(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-usb-pairings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func pairing(key: String, form: USBAccessoryIdentity.Form = .serialNumber)
        -> USBAccessoryPairing
    {
        USBAccessoryPairing(
            key: key, form: form, displayName: "Samsung Type-C",
            receptacleLabel: "Port-USB-C@2", pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("A written set reads back as itself")
    func roundTrip() throws {
        try withBundle { bundleURL in
            let written = USBAccessoryPairingSet(pairings: [
                pairing(key: "04e8:6300:0100:0373"),
                pairing(key: "04e8:6300:0100@hub/Port-A@1", form: .receptacle),
            ])

            try store.save(written, bundleURL: bundleURL)

            #expect(store.load(bundleURL: bundleURL) == written)
        }
    }

    @Test("A bundle with no file holds no pairings")
    func missingFileReadsAsEmpty() throws {
        try withBundle { bundleURL in
            #expect(store.load(bundleURL: bundleURL).isEmpty)
        }
    }

    @Test("An unreadable file holds no pairings rather than throwing")
    func corruptFileReadsAsEmpty() throws {
        try withBundle { bundleURL in
            try Data("{ not json".utf8).write(
                to: VMBundleLayout(bundleURL: bundleURL).usbPairingsURL)

            #expect(store.load(bundleURL: bundleURL).isEmpty)
        }
    }

    @Test("A field the file does not carry decodes to its default")
    func absentFieldsTakeTheirDefaults() throws {
        try withBundle { bundleURL in
            let layout = VMBundleLayout(bundleURL: bundleURL)
            try Data(
                #"{"pairings":[{"key":"k","form":"serialNumber","displayName":"Drive","pairedAt":"2026-09-12T00:00:00Z"}]}"#
                    .utf8
            ).write(to: layout.usbPairingsURL)

            let loaded = store.load(bundleURL: bundleURL)

            #expect(loaded.pairings.count == 1)
            #expect(loaded.pairings.first?.receptacleLabel == nil)
        }
    }

    @Test("A file holding no pairings key reads as no pairings")
    func anObjectWithoutPairingsReadsAsEmpty() throws {
        try withBundle { bundleURL in
            try Data("{}".utf8).write(to: VMBundleLayout(bundleURL: bundleURL).usbPairingsURL)

            #expect(store.load(bundleURL: bundleURL).isEmpty)
        }
    }

    @Test("A second write replaces the first whole")
    func writeReplacesWhatWasThere() throws {
        try withBundle { bundleURL in
            try store.save(
                USBAccessoryPairingSet(pairings: [pairing(key: "a"), pairing(key: "b")]),
                bundleURL: bundleURL)

            try store.save(
                USBAccessoryPairingSet(pairings: [pairing(key: "c")]), bundleURL: bundleURL)

            #expect(store.load(bundleURL: bundleURL).pairings.map(\.key) == ["c"])
        }
    }

    @Test("A write to a bundle that is not there fails rather than inventing one")
    func writeToAMissingBundleThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-absent-\(UUID().uuidString)", isDirectory: true)

        #expect(throws: (any Error).self) {
            try store.save(
                USBAccessoryPairingSet(pairings: [pairing(key: "a")]), bundleURL: missing)
        }
    }
}
