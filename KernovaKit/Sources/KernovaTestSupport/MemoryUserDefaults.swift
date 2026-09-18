import Foundation

// MARK: - MemoryUserDefaults

/// A `UserDefaults` whose store is a dictionary in this process.
///
/// Every typed accessor resolves through the overridden trio: `bool`, `string`,
/// `array`, `stringArray` and `integer` read through `object(forKey:)`, the
/// typed setters write through `set(_:forKey:)`, and `set(nil,…)` clears
/// through `removeObject(forKey:)`. So a value written here reaches no
/// persistent domain and reads back with Foundation's own coercion.
///
/// Only that trio is in memory. `dictionaryRepresentation()` bypasses it and
/// resolves against the host's own search list — the suite plus the
/// application and global domains — where nothing written here appears.
public final class MemoryUserDefaults: UserDefaults {
    /// The suite every instance opens, which nothing ever writes to.
    public static let suiteName =
        "test.kernova.memory.pid\(ProcessInfo.processInfo.processIdentifier)"

    private let lock = NSLock()
    nonisolated(unsafe) private var storage: [String: Any] = [:]

    public override func object(forKey defaultName: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return storage[defaultName]
    }

    public override func set(_ value: Any?, forKey defaultName: String) {
        guard let value else {
            removeObject(forKey: defaultName)
            return
        }
        precondition(
            PropertyListSerialization.propertyList(value, isValidFor: .binary),
            "\(type(of: value)) is not a property list value, which UserDefaults requires")
        lock.lock()
        defer { lock.unlock() }
        storage[defaultName] = value
    }

    public override func removeObject(forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[defaultName] = nil
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
