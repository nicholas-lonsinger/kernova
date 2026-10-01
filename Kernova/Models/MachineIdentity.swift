import CryptoKit
import Foundation

/// The machine identifier a VM boots with — the one value its identity
/// refusals compare and its General section shows.
///
/// A macOS guest boots as a `VZMacMachineIdentifier`, every other guest as a
/// `VZGenericMachineIdentifier`; each case carries that identifier's
/// `dataRepresentation`, so two identities are the same exactly when a guest
/// could not tell them apart.
enum MachineIdentity: Equatable, Sendable {
    case mac(Data)
    case generic(Data)

    /// A short, stable stand-in for the identifier, enough to compare two VMs
    /// by eye: Apple gives the identifier no readable form.
    var fingerprint: Fingerprint { Fingerprint(of: data) }

    private var data: Data {
        switch self {
        case .mac(let data), .generic(let data): data
        }
    }

    /// The SHA-256 of an identifier's data, in uppercase hex.
    struct Fingerprint: Equatable, Sendable {
        /// The whole digest.
        let digest: String

        init(of data: Data) {
            digest = SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
        }

        /// The digest's first eight hex digits as `XXXX-XXXX`.
        var short: String { "\(digest.prefix(4))-\(digest.dropFirst(4).prefix(4))" }
    }
}
