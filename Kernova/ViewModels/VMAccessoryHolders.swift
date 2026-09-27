import Foundation

/// Which VM holds each USB accessory passed through to a guest — the library's
/// one record of it, keyed by the accessory, so one accessory has at most one
/// holder — and which VM is owed back each accessory a warm capture took off
/// its guest.
///
/// Written only by ``VMActivity``: an accessory is reserved in the admission
/// of the operation that attaches it, settled as that attach lands, and
/// released at the operation's ending when it never landed, by a detach, by an
/// unplug, and by the teardown of the holder's session. A return is owed from
/// just before a capture detaches the accessory until its next arrival spends
/// it, the detach fails, or the teardown of that VM's session drops it. Every write takes an
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

    /// Keyed by durable identity rather than `registryID`: the capture's
    /// detach resets the device, and macOS assigns it back under a new one.
    ///
    /// Not a hold. Nothing is reserved while the accessory is off the guest,
    /// so another VM may take it meanwhile, and the owed attach is then
    /// refused as held.
    @ObservationIgnored private var owedReturns: [USBAccessoryIdentity: VMInstance] = [:]

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

    /// The VM owed the return of the accessory carrying `identity`, or `nil`
    /// when none is.
    func owedReturn(of identity: USBAccessoryIdentity) -> VMInstance? {
        owedReturns[identity]
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

    /// Records `attached` as owed back to `instance`, when `instance`'s guest
    /// holds it and something durable identifies it.
    func oweReturn(
        of attached: AttachedUSBAccessory, to instance: VMInstance, _ key: AccessoryHoldersKey
    ) {
        guard let identity = attached.accessory.identity,
            self.attached(to: instance).contains(where: { $0.deviceID == attached.deviceID })
        else { return }
        owedReturns[identity] = instance
    }

    /// Spends the return of `identity` owed to `instance`, answering whether
    /// one was.
    @discardableResult
    func spendOwedReturn(
        of identity: USBAccessoryIdentity, to instance: VMInstance, _ key: AccessoryHoldersKey
    ) -> Bool {
        guard owedReturns[identity] === instance else { return false }
        owedReturns[identity] = nil
        return true
    }

    /// Releases everything `instance` holds, and every return owed to it.
    func releaseAll(of instance: VMInstance, _ key: AccessoryHoldersKey) {
        holders = holders.filter { $0.value.instance !== instance }
        owedReturns = owedReturns.filter { $0.value !== instance }
    }
}
