import Foundation

/// The password for the account a macOS guest is asked to create on its first
/// boot after restore.
///
/// A type of its own rather than a bare `String` so the secret can be neither
/// encoded nor printed: `Codable` is the conformance that would let it reach a
/// bundle's plain-text `config.json`, and ``description`` is what a log line or
/// a debugger dump interpolates.
struct GuestAccountPassword: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    /// The secret, read where the account is created and nowhere else.
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var description: String { "<redacted>" }

    var debugDescription: String { description }
}

/// Where the password for the account a VM owes its guest is held between the
/// door that gathered it and the boot that spends it, keyed by VM identifier.
///
/// A seam because the bundle cannot hold this: `config.json` is plain text
/// beside the disks, so the four values that can live there persist as
/// ``GuestAccountIntent`` and the password is held here instead. Every
/// operation names one VM and nothing else, so a store keeping one item per VM
/// answers all three.
@MainActor
protocol GuestAccountPasswordStoring: AnyObject {
    /// The password held for the VM `id` names, or `nil` when none is.
    func password(for id: UUID) -> GuestAccountPassword?

    /// Holds `password` for the VM `id` names, replacing whatever was held.
    func set(_ password: GuestAccountPassword, for id: UUID)

    /// Drops whatever is held for the VM `id` names. Holding nothing is not a
    /// failure.
    func remove(for id: UUID)
}

/// Holds each VM's password for as long as the app runs.
@MainActor
final class InMemoryGuestAccountPasswordStore: GuestAccountPasswordStoring {
    private var passwords: [UUID: GuestAccountPassword] = [:]

    func password(for id: UUID) -> GuestAccountPassword? { passwords[id] }

    func set(_ password: GuestAccountPassword, for id: UUID) { passwords[id] = password }

    func remove(for id: UUID) { passwords.removeValue(forKey: id) }
}
