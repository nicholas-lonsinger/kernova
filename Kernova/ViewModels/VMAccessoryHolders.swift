import Foundation

/// Which VM holds each USB accessory passed through to a guest — the library's
/// one record of it, keyed by the accessory, so one accessory has at most one
/// holder.
///
/// Written only by ``VMActivity``: an accessory is reserved in the admission
/// of the operation that attaches it, settled as that attach lands, and
/// released at the operation's ending when it never landed, by a detach, by an
/// unplug, and by the teardown of the holder's session. Every write takes an
/// ``AccessoryHoldersKey``, which only `VMActivity.swift` can make.
@MainActor
@Observable
final class VMAccessoryHolders {
    /// How far an accessory's attach has got.
    enum State: Equatable {
        /// Reserved by the operation attaching it, which has not landed yet.
        case attaching
        /// Passed through, as the guest holds it.
        case attached(AttachedUSBAccessory)
    }

    /// The VM holding one accessory, and how far its attach has got.
    struct Holder {
        let instance: VMInstance
        let state: State
        /// Orders the listings by when each accessory was reserved.
        fileprivate let sequence: UInt64
    }

    /// Keyed by `registryID`.
    private var holders: [UInt64: Holder] = [:]
    @ObservationIgnored private var nextSequence: UInt64 = 0

    // MARK: - Reads

    /// The VM holding the accessory `registryID` names, or `nil` when it is
    /// free.
    func holder(of registryID: UInt64) -> VMInstance? {
        holders[registryID]?.instance
    }

    /// Every accessory some VM holds, attached or being attached — what no
    /// listing offers and no automatic attach picks.
    var heldRegistryIDs: Set<UInt64> { Set(holders.keys) }

    /// What `instance`'s guest holds, in the order it was attached.
    func attached(to instance: VMInstance) -> [AttachedUSBAccessory] {
        attachedEntries.filter { $0.instance === instance }.map(\.attached)
    }

    /// Every accessory a guest holds, with the VM holding it, in the order
    /// each was attached.
    var attachedEntries: [(instance: VMInstance, attached: AttachedUSBAccessory)] {
        holders.values.sorted { $0.sequence < $1.sequence }.compactMap { holder in
            guard case .attached(let attached) = holder.state else { return nil }
            return (holder.instance, attached)
        }
    }

    // MARK: - Writes

    /// Reserves `registryID` for `instance`; refuses, changing nothing, while
    /// any VM holds it.
    func reserve(_ registryID: UInt64, for instance: VMInstance, _ key: AccessoryHoldersKey) throws {
        if let holder = holders[registryID] {
            throw VMAdmissionRefusal(refusal: .accessoryHeld(by: holder.instance))
        }
        holders[registryID] = Holder(instance: instance, state: .attaching, sequence: nextSequence)
        nextSequence += 1
    }

    /// Records `attached` as the guest's, answering whether `instance` still
    /// held the reservation for `registryID` — `false` once its session ended
    /// or the operation that reserved it did.
    func settle(
        _ registryID: UInt64, as attached: AttachedUSBAccessory, for instance: VMInstance,
        _ key: AccessoryHoldersKey
    ) -> Bool {
        guard let holder = holders[registryID], holder.instance === instance,
            holder.state == .attaching
        else { return false }
        holders[registryID] = Holder(
            instance: instance, state: .attached(attached), sequence: holder.sequence)
        return true
    }

    /// Releases `instance`'s reservation for `registryID` if its attach never
    /// landed.
    func releaseReservation(
        _ registryID: UInt64, of instance: VMInstance, _ key: AccessoryHoldersKey
    ) {
        guard let holder = holders[registryID], holder.instance === instance,
            holder.state == .attaching
        else { return }
        holders[registryID] = nil
    }

    /// Releases every reservation `instance` holds whose attach never landed.
    func releaseReservations(of instance: VMInstance, _ key: AccessoryHoldersKey) {
        holders = holders.filter { $0.value.instance !== instance || $0.value.state != .attaching }
    }

    /// Releases the attachment `deviceID` names on `instance`, answering it —
    /// `nil` when `instance` holds no such attachment.
    @discardableResult
    func release(
        deviceID: UUID, of instance: VMInstance, _ key: AccessoryHoldersKey
    ) -> AttachedUSBAccessory? {
        for (registryID, holder) in holders where holder.instance === instance {
            guard case .attached(let attached) = holder.state, attached.deviceID == deviceID
            else { continue }
            holders[registryID] = nil
            return attached
        }
        return nil
    }

    /// Releases everything `instance` holds.
    func releaseAll(of instance: VMInstance, _ key: AccessoryHoldersKey) {
        holders = holders.filter { $0.value.instance !== instance }
    }
}
