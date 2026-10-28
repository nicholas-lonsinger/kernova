#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

extension Connection {
    /// The next frames to write, in §3.5's order, built from pending state:
    /// at least one whole frame even past `maxBytes`; nil when nothing is pending
    /// and after the final transmit.
    public mutating func pollTransmit(maxBytes: Int) -> Transmit? {
        guard state != .finished, !finalHandedOut else { return nil }
        var chunks: [Data] = []
        var used = 0
        if !preambleSent {
            preambleSent = true
            chunks.append(WireConstants.preamble)
            used += WireConstants.preamble.count
        }
        var isFinal = false
        while let frame = takeFrame(fitting: chunks.isEmpty ? nil : maxBytes - used) {
            for part in FrameEncoder.encode(frame) where !part.isEmpty {
                chunks.append(part)
                used += part.count
            }
            if frame.streamID == .session, frame.type == .reset {
                isFinal = true
                finalHandedOut = true
                break
            }
        }
        guard !chunks.isEmpty else { return nil }
        return Transmit(chunks: chunks, isFinal: isFinal)
    }

    /// Pops the next frame in transmit order whose encoding fits `budget` bytes
    /// (any size when nil); nil when nothing is pending or the next does not fit.
    mutating func takeFrame(fitting budget: Int?) -> Frame? {
        func fits(_ payloadCount: Int) -> Bool {
            budget.map { WireConstants.headerByteCount + payloadCount <= $0 } ?? true
        }
        if state == .closing, !closeDrainsQueue {
            return takeConnectionReset(fits)
        }
        // 2. Stream-0 session messages, in the order queued.
        if let slot = sessionQueue.first, let payload = sessionPayloads[slot.rawValue] {
            guard fits(payload.count) else { return nil }
            sessionQueue.removeFirst()
            sessionPayloads[slot.rawValue] = nil
            return Frame(streamID: .session, type: .data, flags: .message, payload: payload)
        }
        // 3. The connection WINDOW.
        if pendingConnectionWindow > 0 {
            guard fits(WireConstants.windowPayloadByteCount) else { return nil }
            let increment = UInt32(pendingConnectionWindow)
            pendingConnectionWindow = 0
            return Frame(streamID: .session, type: .window, payload: Self.bigEndian(increment))
        }
        // 4. PING.
        if pingPending {
            guard fits(WireConstants.pingPayloadByteCount) else { return nil }
            pingPending = false
            pingCounter &+= 1
            return Frame(streamID: .session, type: .ping, payload: Self.bigEndian(pingCounter))
        }
        // 5. Stream RESETs, then 6. stream WINDOWs, in id order.
        if let index = streams.firstIndex(where: { $0.pendingReset != nil && $0.openHandedOut }),
            let error = streams[index].pendingReset
        {
            let payload = error.proto.encoded
            guard fits(payload.count) else { return nil }
            streams[index].pendingReset = nil
            let id = streams[index].id
            if streams[index].isRetired { streams.remove(at: index) }
            return Frame(streamID: id, type: .reset, payload: payload)
        }
        if let index = streams.firstIndex(where: { $0.pendingWindow > 0 && $0.openHandedOut }) {
            guard fits(WireConstants.windowPayloadByteCount) else { return nil }
            let increment = UInt32(streams[index].pendingWindow)
            streams[index].pendingWindow = 0
            return Frame(streamID: streams[index].id, type: .window, payload: Self.bigEndian(increment))
        }
        if state == .closing {
            return takeConnectionReset(fits)
        }
        // 7. The lowest-id unsent OPEN: ids are allocated in increasing order, so OPENs leave in id order.
        if let index = streams.firstIndex(where: \.frontIsOpen) {
            return takeFront(at: index, fits)
        }
        // 8. Each stream's FIFO whose OPEN has left, round-robin by id, one frame per stream per turn.
        return takeStreamFrame(fits)
    }

    mutating func takeConnectionReset(_ fits: (Int) -> Bool) -> Frame? {
        guard let closeError else { return nil }
        let payload = closeError.proto.encoded
        guard fits(payload.count) else { return nil }
        return Frame(streamID: .session, type: .reset, payload: payload)
    }

    mutating func takeStreamFrame(_ fits: (Int) -> Bool) -> Frame? {
        guard !streams.isEmpty else { return nil }
        let start = streams.firstIndex { $0.id.rawValue > roundRobinAfter } ?? 0
        for step in 0..<streams.count {
            let index = (start + step) % streams.count
            guard streams[index].openHandedOut, streams[index].hasQueuedFrames else { continue }
            let id = streams[index].id
            guard let frame = takeFront(at: index, fits) else { return nil }
            roundRobinAfter = id.rawValue
            return frame
        }
        return nil
    }

    /// Hands out the front of `index`'s FIFO when it fits; nil when it does not.
    mutating func takeFront(at index: Int, _ fits: (Int) -> Bool) -> Frame? {
        guard let front = streams[index].frontFrame else { return nil }
        let id = streams[index].id
        let frame: Frame
        switch front {
        case .open(let payload): frame = Frame(streamID: id, type: .open, payload: payload)
        case .window(let increment): frame = Frame(streamID: id, type: .window, payload: Self.bigEndian(increment))
        case .message(let payload): frame = Frame(streamID: id, type: .data, flags: .message, payload: payload)
        case .data(let payload): frame = Frame(streamID: id, type: .data, payload: payload)
        case .end(let payload): frame = Frame(streamID: id, type: .end, payload: payload)
        }
        guard fits(frame.payload.count) else { return nil }
        _ = streams[index].popFrame()
        switch front {
        case .open:
            streams[index].openHandedOut = true
            highestLocalHandedOut = id.rawValue
        case .data(let payload):
            streams[index].queuedRaw -= payload.count
            queuedRawTotal -= payload.count
        case .message:
            streams[index].unsentMessages -= 1
        case .window, .end:
            break
        }
        if streams[index].isRetired {
            streams.remove(at: index)
        } else if case .message = front {
            refreshWritable(at: index)
        }
        return frame
    }

    static func bigEndian(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
        ])
    }

    static func bigEndian(_ value: UInt64) -> Data {
        bigEndian(UInt32(truncatingIfNeeded: value >> 32)) + bigEndian(UInt32(truncatingIfNeeded: value))
    }

    // MARK: - Session queue (§3.5 step 2)

    /// Queues a session message; a snapshot replaces an unsent one of its kind in place.
    mutating func queueSession(_ slot: SessionSlot, payload: Data) {
        if sessionPayloads[slot.rawValue] == nil {
            sessionQueue.append(slot)
        }
        sessionPayloads[slot.rawValue] = payload
    }

    func helloMessage() -> Kernova_V2_SessionMessage {
        var hello = Kernova_V2_Hello()
        hello.protocolVersion = configuration.protocolVersion
        hello.identity = configuration.claim.proto
        hello.features = localAdverts.map(\.proto)
        if role != .host {
            hello.state = (configuration.initialState ?? PeerSessionState()).proto
        }
        hello.sessionToken = role == .host ? configuration.sessionToken : Data()
        var message = Kernova_V2_SessionMessage()
        message.hello = hello
        return message
    }

    func policyMessage(_ policy: PolicySnapshot) -> Kernova_V2_SessionMessage {
        var update = Kernova_V2_PolicyUpdate()
        update.features = policy.entries.map { entry in
            var feature = Kernova_V2_FeaturePolicy()
            feature.feature = entry.feature
            feature.version = entry.version
            feature.enabled = entry.enabled
            feature.params = entry.params
            return feature
        }
        var message = Kernova_V2_SessionMessage()
        message.policy = update
        return message
    }

    func updateAvailableMessage(_ manifest: UpdateManifestValue?) -> Kernova_V2_SessionMessage {
        var available = Kernova_V2_UpdateAvailable()
        if let manifest { available.manifest = manifest.proto }
        var message = Kernova_V2_SessionMessage()
        message.updateAvailable = available
        return message
    }

    // MARK: - Session commands

    /// Replaces this side's adverts and queues a `CapabilityUpdate` when they changed.
    public mutating func setLocalAdverts(_ adverts: [(FeatureID, LocalAdvert)]) {
        let sorted = Self.sortedAdverts(adverts)
        guard sorted != localAdverts else { return }
        localAdverts = sorted
        guard isAcceptingInput else { return }
        var update = Kernova_V2_CapabilityUpdate()
        update.features = sorted.map(\.proto)
        var message = Kernova_V2_SessionMessage()
        message.capabilities = update
        queueSession(.capabilities, payload: message.encoded)
    }

    /// Peer only: queues a `PeerState` snapshot when the state changed. The
    /// session id is fixed for the connection.
    public mutating func setPeerState(_ state: PeerSessionState) {
        guard role != .host else { return misuse("setPeerState on the host") }
        guard state != lastPeerState else { return }
        if let lastPeerState, role == .sessionPeer, lastPeerState.sessionID != state.sessionID {
            return misuse("a session peer's session id changed")
        }
        lastPeerState = state
        guard isAcceptingInput else { return }
        var message = Kernova_V2_SessionMessage()
        message.peerState = state.proto
        queueSession(.peerState, payload: message.encoded)
    }

    /// Host only: replaces the policy and, once the peer's Hello is read, queues a `PolicyUpdate`.
    public mutating func setPolicy(_ policy: PolicySnapshot) {
        guard role == .host else { return misuse("setPolicy on a peer") }
        guard policy != currentPolicy else { return }
        currentPolicy = policy
        guard state == .established else { return }
        queueSession(.policy, payload: policyMessage(policy).encoded)
    }

    /// Host only: replaces the bundles and, once the peer's Hello is read, queues
    /// an `UpdateAvailable` when the offer for this peer changed.
    public mutating func setBundles(_ bundles: [BundledPayload]) {
        guard role == .host else { return misuse("setBundles on a peer") }
        let before = offeredUpdate
        hostBundles = bundles
        guard state == .established, offeredUpdate != before else { return }
        queueSession(.updateAvailable, payload: updateAvailableMessage(offeredUpdate).encoded)
    }
}

extension FeatureAdvertValue {
    var proto: Kernova_V2_FeatureAdvert {
        var advert = Kernova_V2_FeatureAdvert()
        advert.feature = feature
        advert.version = self.advert.version
        switch self.advert.availability {
        case .available(let params):
            advert.params = params
        case .absent(let reason, let detail):
            var absence = Kernova_V2_Absence()
            absence.reason = reason
            absence.debugDetail = Normalize.clip(detail, maxBytes: Normalize.debugDetailBytes)
            advert.absent = absence
        }
        return advert
    }
}
