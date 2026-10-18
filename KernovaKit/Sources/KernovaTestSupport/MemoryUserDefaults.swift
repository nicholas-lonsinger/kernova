import Foundation
import KernovaSynchronization

// MARK: - MemoryUserDefaults

/// A `UserDefaults` whose store is a dictionary in this process.
///
/// Every typed accessor resolves through the overridden trio: `bool`, `string`,
/// `array`, `stringArray` and `integer` read through `object(forKey:)`, the
/// typed setters write through `set(_:forKey:)`, and `set(nil,…)` clears
/// through `removeObject(forKey:)`. So a value written here reaches no
/// persistent domain and reads back with Foundation's own coercion.
///
/// Each value is held as its binary property-list encoding, so a read returns
/// a fresh copy, as a persistent domain's would.
///
/// Only that trio is in memory. `dictionaryRepresentation()` bypasses it and
/// resolves against the host's own search list — the suite plus the
/// application and global domains — where nothing written here appears.
public final class MemoryUserDefaults: UserDefaults {
    /// The suite every instance opens, which nothing ever writes to.
    public static let suiteName =
        "test.kernova.memory.pid\(ProcessInfo.processInfo.processIdentifier)"

    private let storage = Locked<[String: Data]>([:])

    public override func object(forKey defaultName: String) -> Any? {
        guard let encoded = storage.withLock({ $0[defaultName] }) else { return nil }
        do {
            return try PropertyListSerialization.propertyList(from: encoded, format: nil)
        } catch {
            preconditionFailure("A stored property list failed to decode: \(error)")
        }
    }

    public override func set(_ value: Any?, forKey defaultName: String) {
        guard let value else {
            removeObject(forKey: defaultName)
            return
        }
        precondition(
            PropertyListSerialization.propertyList(value, isValidFor: .binary),
            "\(type(of: value)) is not a property list value, which UserDefaults requires")
        let encoded: Data
        do {
            encoded = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        } catch {
            preconditionFailure("\(type(of: value)) failed to encode as a property list: \(error)")
        }
        storage.withLock { $0[defaultName] = encoded }
    }

    public override func removeObject(forKey defaultName: String) {
        storage.withLock { $0[defaultName] = nil }
    }
}

// MARK: - makeTestDefaults

/// A `UserDefaults` for a test to write through, holding its values in memory.
public func makeTestDefaults() -> MemoryUserDefaults {
    guard let defaults = MemoryUserDefaults(suiteName: MemoryUserDefaults.suiteName) else {
        fatalError("Could not open test UserDefaults suite '\(MemoryUserDefaults.suiteName)'")
    }
    return defaults
}
