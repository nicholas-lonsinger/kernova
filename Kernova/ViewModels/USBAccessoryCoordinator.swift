import Foundation
import KernovaKit
import os

/// One accessory nobody has placed, and the running guests that could take it.
///
/// Raised by the coordinator and answered by whichever surface asked the user.
/// The answer writes nothing itself: it goes back through the attach verb, so
/// the pairing is written by the one path every attach takes.
struct USBAccessoryPairingRequest {
    /// Identifies this prompt, so a second answer to it is ignored.
    let id: UUID
    /// The accessory, named the way a listing would name it — qualified by its
    /// receptacle where another accessory would read identically.
    let accessory: USBAccessorySummary
    /// The guests that could take it, in library order.
    let candidates: [VMInstance]
    /// Answers the prompt: a VM to pass the accessory through to, or `nil` to
    /// keep it on the Mac.
    let answer: @MainActor (VMInstance?) -> Void
}

/// Starts the accessory listener, keeps each guest's record of what it holds
/// honest, and hands an accessory back to the guest it was last placed on.
///
/// macOS answers *whether* — the user assigns the accessory to Kernova in
/// Apple's *Virtual Machine Accessories* menu extra. *Which VM* is the user's
/// answer too, given once: placing an accessory on a guest records a pairing
/// against that VM, and from then on the accessory goes back to it whenever
/// both are available — on assignment, and when the VM starts. An accessory no
/// pairing names is offered to the user while a guest is running, and held for
/// the host otherwise.
///
/// Taking an accessory back by hand undoes that: the pairing is dropped and the
/// re-enumeration the detach causes is consumed silently, so the device stays
/// with the Mac rather than being handed straight back to the guest it just
/// left.
///
/// Reconciliation runs on every arrival, whatever the routing then decides.
/// Detaching a passthrough device resets the device, so the stick comes back as
/// a new IORegistry node: an assignment carrying the identity of something a
/// guest is still recorded as holding is proof that guest no longer holds it.
///
/// It is also what tells the service which keys are already spoken for, so a
/// second unit of a model whose vendor duplicated the serial cannot compose the
/// key a guest's record carries.
@MainActor
final class USBAccessoryCoordinator {
    private static let logger = Logger(subsystem: "app.kernova", category: "USBAccessoryCoordinator")

    private let roster: any VMInstanceRoster
    private let pairings: any USBAccessoryPairingWriting
    private let lifecycle: VMLifecycleCoordinator
    private let service: any USBAccessoryProviding

    /// Accessories the user has just taken back by hand, each spent by the next
    /// assignment carrying it.
    ///
    /// A one-shot token rather than a time window: a detach re-enumerates the
    /// device and macOS hands it back after a delay nothing bounds, and the
    /// returning unit must neither be re-attached nor prompted for. A token
    /// whose device never comes back is inert; a genuine replug of the same unit
    /// in the same port before the token is spent costs one suppressed prompt
    /// and leaves the accessory with the host, one menu item from being placed.
    private var releasedByUser: Set<USBAccessoryIdentity> = []

    /// Prompts not yet raised, and the one that is.
    ///
    /// macOS re-assigns every accessory after a fast user switch, so a machine
    /// with several unpaired ones would otherwise raise several alerts at once.
    private var pendingPrompts: [USBAccessoryPairingRequest] = []
    private var outstandingPromptID: UUID?

    /// Asks the user which guest an unpaired accessory should go to.
    ///
    /// `nil` — or a surface with nowhere to put an alert — means the accessory
    /// is held for the host, which is what it would be anyway until the user
    /// places it from the USB Device menu.
    var onPairingNeeded: (@MainActor (USBAccessoryPairingRequest) -> Void)?

    init?(
        lifecycle: VMLifecycleCoordinator,
        roster: any VMInstanceRoster,
        pairings: any USBAccessoryPairingWriting
    ) {
        guard let service = lifecycle.usbAccessoryService else { return nil }
        self.lifecycle = lifecycle
        self.roster = roster
        self.pairings = pairings
        self.service = service

        service.accessoriesHeldByGuests = { [weak self] in
            self?.accessoriesHeldByGuests() ?? []
        }
        service.onAccessoryAssigned = { [weak self] info, arrival in
            self?.accessoryAssigned(info, arrival: arrival)
        }
        service.startObserving()
    }

    // MARK: - Arrival

    /// Decides what happens to an accessory macOS has just assigned to Kernova.
    private func accessoryAssigned(_ info: USBAccessoryInfo, arrival: USBAccessoryArrival) {
        reconcile(info)
        guard arrival == .fresh else {
            // A capture's put-back was already waiting for this exact unit and
            // has just been handed it; it owns the accessory from here.
            return
        }
        // Nothing durable names it, so no pairing can and none could be written
        // from a prompt either. `USBAccessoryService.logIdentityGaps` has
        // already said why.
        guard let identity = info.identity else { return }

        if releasedByUser.remove(identity) != nil {
            Self.logger.notice(
                "Holding USB accessory \(info.displayName, privacy: .public) for the host: it came back from a detach the user asked for"
            )
            return
        }

        let claimants = roster.instances.filter {
            $0.usbPairings.pairing(matching: identity) != nil
        }
        guard let paired = claimants.first else {
            offerToRunningGuests(info)
            return
        }
        // Hand-edited files, or a bundle copied outside the app. Which VM the
        // device belongs to is not decidable, and guessing routes hardware into
        // the wrong guest.
        guard claimants.count == 1 else {
            Self.logger.warning(
                "Holding USB accessory \(info.displayName, privacy: .public): \(claimants.count) virtual machines claim the same accessory (\(identity.key, privacy: .public))"
            )
            return
        }
        // A key built on a receptacle names whatever is in that port. With a
        // second unit of the same model around, the one in the port may be
        // either of them.
        if identity.form == .receptacle, sharesItsModel(info) {
            Self.logger.notice(
                "Holding USB accessory \(info.displayName, privacy: .public): it is identified by its port, and more than one accessory of that model is connected"
            )
            return
        }
        guard paired.attachableSessionID != nil else {
            Self.logger.notice(
                "Holding USB accessory \(info.displayName, privacy: .public) for the host: '\(paired.name, privacy: .public)' is not running"
            )
            return
        }
        Task { await autoAttach(info.registryID, to: paired) }
    }

    /// Drops any guest's record of an accessory that has just re-enumerated.
    ///
    /// The match is on the durable identity, never on `registryID`: the whole
    /// point is that the returning device carries a new one. Identity equality
    /// takes the receptacle with it, so what is dropped is the record of a unit
    /// that came back in the hole it left — which is what a reset does, and
    /// what a second unit of the same model arriving elsewhere does not.
    ///
    /// A guest whose device really did go away has usually been told so by VZ
    /// already, so a drop here is worth a `.notice`: it means the disconnect
    /// callback did not arrive.
    private func reconcile(_ info: USBAccessoryInfo) {
        guard let identity = info.identity else { return }
        for instance in roster.instances {
            guard let sessionID = instance.liveSessionID else { continue }
            for stale in instance.liveUSBAccessories
            where stale.accessory.identity == identity {
                instance.forgetAttachedAccessory(deviceID: stale.deviceID, for: sessionID)
                Self.logger.notice(
                    "Dropped '\(instance.name, privacy: .public)' record of USB accessory \(stale.accessory.displayName, privacy: .public): the host has it again, and VZ did not report the disconnect"
                )
            }
        }
    }

    // MARK: - VM Start

    /// Hands `instance` every accessory paired with it that is sitting with the
    /// host, now that it can take one.
    ///
    /// Wired to ``VMInstance/onSessionBecameAttachable``, so it runs once per
    /// session rather than on every arrival at a live phase.
    func sessionBecameAttachable(_ instance: VMInstance) {
        let held = Set(accessoriesHeldByGuests().map(\.registryID))
        let owed = service.accessories.filter { accessory in
            guard !held.contains(accessory.registryID), let identity = accessory.identity else {
                return false
            }
            guard instance.usbPairings.pairing(matching: identity) != nil else { return false }
            guard claimantCount(of: identity) == 1 else { return false }
            return !(identity.form == .receptacle && sharesItsModel(accessory))
        }
        guard !owed.isEmpty else { return }
        Task { [weak self] in
            // One at a time: each attach is serialized on the instance, and a
            // second issued under the first would be refused outright.
            for accessory in owed {
                await self?.autoAttach(accessory.registryID, to: instance)
            }
        }
    }

    // MARK: - The One Automatic Attach

    /// Passes the accessory `registryID` names through to `instance`, once
    /// whatever that VM is doing has settled.
    ///
    /// The wait is what makes the re-checks below answer about the VM's settled
    /// state: `VMLifecycleCoordinator` rejects a concurrent operation rather
    /// than queueing it, and a save, a stop or a snapshot capture ejects every
    /// passthrough device and can rest at a phase that still reads as live
    /// while it does. Waiting first means a device re-assigned under a save is
    /// held, because by the time this looks the VM is suspended.
    ///
    /// Nothing is alerted about: the user did not ask for this attach, so a
    /// failure leaves the accessory with the host and says so in the log.
    private func autoAttach(_ registryID: UInt64, to instance: VMInstance) async {
        _ = await lifecycle.awaitSettledOutcome(for: instance.id)
        guard let sessionID = instance.attachableSessionID else {
            Self.logger.notice(
                "Holding USB accessory \(registryID) for the host: '\(instance.name, privacy: .public)' stopped being able to take one"
            )
            return
        }
        guard let accessory = service.accessories.first(where: { $0.registryID == registryID })
        else { return }
        guard !accessoriesHeldByGuests().contains(where: { $0.registryID == registryID }) else {
            return
        }
        do {
            _ = try await lifecycle.attachUSBAccessory(registryID, to: instance, for: sessionID)
            Self.logger.notice(
                "Passed USB accessory \(accessory.displayName, privacy: .public) through to '\(instance.name, privacy: .public)': it is paired with that virtual machine"
            )
        } catch {
            Self.logger.warning(
                "Could not pass USB accessory \(accessory.displayName, privacy: .public) through to '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - The User's Own Edits

    /// Records the pairing an attach the user asked for creates, and takes the
    /// accessory's key off every other VM.
    func userAttached(_ accessory: USBAccessoryInfo, to instance: VMInstance) {
        guard let pairing = USBAccessoryPairing.make(for: accessory) else { return }
        pairings.pairUSBAccessory(pairing, with: instance)
        Self.logger.notice(
            "'\(instance.name, privacy: .public)' will take USB accessory \(accessory.displayName, privacy: .public) back automatically"
        )
    }

    /// Forgets the pairing a detach the user asked for ends, and arms the token
    /// that keeps the detach's own echo from undoing it.
    ///
    /// Both halves or neither: the detach re-enumerates the device and macOS
    /// hands it straight back, so a forgotten pairing without the token would
    /// prompt on every detach, and a token without the forgetting would attach
    /// the device again before the user could pick it up.
    func userReleased(_ accessory: USBAccessoryInfo, from instance: VMInstance) {
        guard let identity = accessory.identity else { return }
        releasedByUser.insert(identity)
        pairings.updateUSBPairings(of: instance) { $0.remove(key: identity.key) }
        Self.logger.notice(
            "'\(instance.name, privacy: .public)' will no longer take USB accessory \(accessory.displayName, privacy: .public) back automatically"
        )
    }

    // MARK: - Prompting

    /// Offers `info` to the running guests, or holds it when there are none.
    private func offerToRunningGuests(_ info: USBAccessoryInfo) {
        let candidates = roster.instances.filter { $0.attachableSessionID != nil }
        guard !candidates.isEmpty else {
            Self.logger.notice(
                "Holding USB accessory \(info.displayName, privacy: .public) for the host: no virtual machine is running"
            )
            return
        }
        let id = UUID()
        let names = USBAccessoryInfo.listingNames(
            for: service.accessories + accessoriesHeldByGuests())
        pendingPrompts.append(
            USBAccessoryPairingRequest(
                id: id,
                accessory: USBAccessorySummary(
                    registryID: info.registryID,
                    name: names[info.registryID] ?? info.displayName,
                    vendorID: info.descriptor.vendorID,
                    productID: info.descriptor.productID),
                candidates: candidates,
                answer: { [weak self] instance in self?.promptAnswered(id, with: instance) }))
        raiseNextPrompt()
    }

    private func raiseNextPrompt() {
        guard outstandingPromptID == nil, !pendingPrompts.isEmpty else { return }
        let request = pendingPrompts.removeFirst()
        guard let onPairingNeeded else {
            Self.logger.notice(
                "Holding USB accessory \(request.accessory.name, privacy: .public) for the host: there is nowhere to ask which virtual machine should take it"
            )
            raiseNextPrompt()
            return
        }
        outstandingPromptID = request.id
        onPairingNeeded(request)
    }

    /// Releases the prompt slot, ignoring an answer to a prompt that is no
    /// longer the outstanding one — a sheet answered twice, or one abandoned.
    private func promptAnswered(_ id: UUID, with instance: VMInstance?) {
        guard outstandingPromptID == id else { return }
        outstandingPromptID = nil
        if instance == nil {
            Self.logger.notice("A USB accessory the user was asked about stays with the host")
        }
        raiseNextPrompt()
    }

    // MARK: - Support

    private func accessoriesHeldByGuests() -> [USBAccessoryInfo] {
        roster.instances.flatMap { $0.liveUSBAccessories.map(\.accessory) }
    }

    /// How many VMs in the library claim `identity`.
    private func claimantCount(of identity: USBAccessoryIdentity) -> Int {
        roster.instances.filter { $0.usbPairings.pairing(matching: identity) != nil }.count
    }

    /// Whether another accessory Kernova knows about is of the same model as
    /// `info` — the ambiguity a port-keyed pairing cannot resolve.
    private func sharesItsModel(_ info: USBAccessoryInfo) -> Bool {
        let known = service.accessories + accessoriesHeldByGuests()
        return known.filter { $0.descriptor.modelKey == info.descriptor.modelKey }.count > 1
    }
}
