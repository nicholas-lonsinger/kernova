import Foundation

/// What two VMs share of the identity a guest and its network see.
///
/// Recognized by what the two share, never by how they arose: nothing records
/// that one was cloned from the other, and a Finder duplicate that was
/// imported is an exact copy as much as a clone is.
enum VMIdentityKinship: Equatable {
    /// One machine identity and one MAC address — none at all counting as one.
    case exactCopy
    /// One machine identity under different MAC addresses.
    case sharedMachineIdentity
    /// One MAC address under different machine identities — the fault
    /// docs/NETWORKING.md discloses, which no clone authors.
    case sharedMACAddress

    /// The kinship of two VMs that share a machine identity or not, carrying
    /// the two MAC addresses — `nil` when they share neither.
    init?(sharingMachineIdentity: Bool, macAddresses a: String?, _ b: String?) {
        let sameMAC = a?.lowercased() == b?.lowercased()
        switch (sharingMachineIdentity, sameMAC) {
        case (true, true): self = .exactCopy
        case (true, false): self = .sharedMachineIdentity
        case (false, true) where a != nil: self = .sharedMACAddress
        case (false, _): return nil
        }
    }
}

extension VMInstance {
    /// What this VM shares with `other`, brought up under `configuration` —
    /// its own unless given — or `nil` when it shares nothing.
    func kinship(
        with other: VMInstance, bringingUp configuration: VMConfiguration? = nil
    ) -> VMIdentityKinship? {
        VMIdentityKinship(
            sharingMachineIdentity: sharesMachineIdentity(with: other),
            macAddresses: (configuration ?? self.configuration).macAddress,
            other.configuration.macAddress)
    }

    /// Whether this VM and `other` claim the same machine identity — the one
    /// comparison every identity check reads.
    ///
    /// macOS identifiers compare the *effective* value, which falls back to the
    /// bundle's identifier file exactly as the boot path does; generic
    /// identifiers have no such file, so they compare configuration fields. A
    /// VM with no identifier shares it with no one.
    func sharesMachineIdentity(with other: VMInstance) -> Bool {
        if let lhs = effectiveMachineIdentifierData, let rhs = other.effectiveMachineIdentifierData,
            lhs == rhs
        {
            return true
        }
        if let lhs = configuration.genericMachineIdentifierData,
            let rhs = other.configuration.genericMachineIdentifierData,
            lhs == rhs
        {
            return true
        }
        return false
    }
}
