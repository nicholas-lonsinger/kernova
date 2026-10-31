#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import SwiftProtobuf

extension Connection {
    // MARK: - Time

    /// Advances both clocks to `now` and evaluates every deadline.
    package mutating func tick(_ now: CoreInstant) {
        clock.advance(to: now)
        evaluate()
    }

    /// Ends a receive turn: its frames are processed, so any of them has already
    /// replaced the deadlines it ends before they are evaluated.
    package mutating func finishReceive() {
        evaluate()
    }

    mutating func evaluate() {
        switch state {
        case .finished:
            return
        case .closing:
            if let closingDeadline, clock.raw >= closingDeadline { finish() }
            return
        case .handshaking, .established:
            break
        }
        rollDiagnosticWindow()
        if !clock.isFrozen, clock.raw >= nextPingAt {
            pingPending = true
            // Anchored to the due instant, so lateness never accumulates; a turn
            // a whole interval late skips the PINGs it missed rather than bursting.
            let interval = max(policy.pingInterval.nanoseconds, 1)
            let late = nextPingAt.duration(to: clock.raw).nanoseconds
            nextPingAt = nextPingAt.advanced(by: CoreDuration(nanoseconds: (late / interval + 1) * interval))
        }
        if state == .handshaking, var deadline = helloDeadline {
            let fires = deadline.evaluate(clock)
            helloDeadline = deadline
            if fires { return fatal(.helloTimeout, "no Hello within the Hello timeout") }
        }
        if state == .established {
            if var deadline = unresponsiveDeadline {
                let fires = deadline.evaluate(clock)
                unresponsiveDeadline = fires ? nil : deadline
                if fires {
                    isUnresponsive = true
                    emit(.liveness(.unresponsive(silentFor: lastHeard.duration(to: clock.judged))))
                }
            }
            if var deadline = livenessCloseDeadline {
                let fires = deadline.evaluate(clock)
                livenessCloseDeadline = deadline
                if fires { return fatal(.livenessExpired, "the far side was silent past the close threshold") }
            }
        }
        for index in streams.indices where streams[index].returnBucket != nil {
            returnStreamCredit(at: index)
        }
    }

    // MARK: - Frames

    /// Handles the next buffered frame; false when none is whole or input is over.
    package mutating func processNextFrame() -> Bool {
        guard isAcceptingInput else { return false }
        let frame: Frame?
        do {
            frame = try decoder.nextFrame()
        } catch {
            if let code = error.closeCode {
                fatal(code, "\(error)")
            } else {
                closeAllStreams(.connectionLost, keepPendingResets: false)
                dropAllQueues()
                finish()
                emit(.closed(.notThisProtocol))
            }
            return true
        }
        guard let frame else { return false }
        if state == .handshaking {
            handleFirstFrame(frame)
        } else {
            noteHeard()
            if frame.streamID == .session {
                handleSessionFrame(frame)
            } else {
                handleStreamFrame(frame)
            }
        }
        return true
    }

    mutating func noteHeard() {
        lastHeard = clock.judged
        let confirmation = policy.expiryConfirmation
        unresponsiveDeadline = JudgedDeadline(after: policy.unresponsiveAfter, on: clock, confirmation: confirmation)
        livenessCloseDeadline = JudgedDeadline(after: policy.closeAfter, on: clock, confirmation: confirmation)
        if isUnresponsive {
            isUnresponsive = false
            emit(.liveness(.responsive))
        }
    }

    // MARK: - Hello

    mutating func handleFirstFrame(_ frame: Frame) {
        if frame.streamID == .session, frame.type == .reset {
            return receiveConnectionReset(frame.payload)
        }
        guard frame.streamID == .session, frame.type == .data, frame.flags.contains(.message),
            let message = try? Kernova_V2_SessionMessage(serializedBytes: frame.payload),
            case .hello(let hello) = message.message
        else { return fatal(.protocolError, "the first frame is not a Hello") }
        guard let claim = PeerClaim(received: hello.identity) else {
            return fatal(.protocolError, "the Hello's role is unspecified")
        }
        var state: PeerSessionState?
        switch (role, claim.role) {
        case (.host, .sessionPeer):
            let received = PeerSessionState(received: hello.state)
            guard hello.hasState, !received.sessionID.isEmpty else {
                return fatal(.protocolError, "a session peer's Hello has no session_id")
            }
            state = received
        case (.host, .systemPeer):
            guard claim.scope == .system else {
                return fatal(.protocolError, "a system peer's Hello claims a scope other than SYSTEM")
            }
            state = PeerSessionState(received: hello.state)
        case (.sessionPeer, .host), (.systemPeer, .host):
            state = nil
        default:
            return fatal(.protocolError, "a Hello with a role this side does not accept")
        }
        let adverts = receivedAdverts(hello.features, remoteVersion: hello.protocolVersion)
        remoteAdverts = adverts
        remoteState = state
        remoteHello = RemoteHello(
            protocolVersion: hello.protocolVersion, claim: claim, state: state, adverts: adverts.map(\.value),
            sessionToken: Normalize.clip(hello.sessionToken, maxBytes: Normalize.hashBytes))
        self.state = .established
        helloDeadline = nil
        noteHeard()
        if let remoteHello { emit(.helloReceived(remoteHello)) }
        if role == .host {
            queueSession(.policy, payload: policyMessage(currentPolicy ?? PolicySnapshot()).encoded)
            queueSession(.updateAvailable, payload: updateAvailableMessage(offeredUpdate).encoded)
        }
    }

    /// The far side's adverts, normalized, each one's params decoded once; for a
    /// feature that is frozen or whose protocol version both sides share, and that
    /// this side advertises at the same version, params that do not decode make
    /// the advert absent.
    mutating func receivedAdverts(_ features: [Kernova_V2_FeatureAdvert], remoteVersion: UInt32)
        -> [ReceivedAdvert]
    {
        var adverts: [ReceivedAdvert] = []
        for advert in features {
            guard let descriptor = FeatureDescriptor.lookup(advert.feature),
                !adverts.contains(where: { $0.value.feature == advert.feature })
            else { continue }
            var availability: Availability<Data>
            switch advert.availability {
            case .params(let params):
                availability = .available(params)
            case .absent(let absence):
                let raw = absence.reason.rawValue
                let reason = (1...99).contains(raw) ? absence.reason : .unspecified
                availability = .absent(
                    reason, debugDetail: Normalize.display(absence.debugDetail, maxBytes: Normalize.debugDetailBytes))
            case nil:
                availability = .absent(.unspecified, debugDetail: "")
            }
            var paramsDecode = true
            if case .available(let params) = availability {
                paramsDecode = descriptor.paramsDecode(params)
                if !paramsDecode, descriptor.frozen || remoteVersion == configuration.protocolVersion,
                    localAdverts.first(where: { $0.feature == advert.feature })?.advert.version == advert.version
                {
                    availability = .absent(.unspecified, debugDetail: "params do not decode")
                    diagnose(.remoteViolation("\(advert.feature) params do not decode"))
                }
            }
            adverts.append(
                ReceivedAdvert(
                    value: FeatureAdvertValue(
                        feature: advert.feature,
                        advert: LocalAdvert(version: advert.version, availability: availability)),
                    paramsDecode: paramsDecode))
        }
        return adverts.sorted { $0.value.feature.rawValue < $1.value.feature.rawValue }
    }

    // MARK: - Stream 0

    mutating func handleSessionFrame(_ frame: Frame) {
        switch frame.type {
        case .data:
            guard frame.flags.contains(.message) else { return fatal(.protocolError, "raw DATA on stream 0") }
            guard let message = try? Kernova_V2_SessionMessage(serializedBytes: frame.payload) else {
                return fatal(.protocolError, "a stream-0 payload that is not a SessionMessage")
            }
            handleSessionMessage(message)
        case .open, .end:
            fatal(.protocolError, "\(frame.type) on stream 0")
        case .reset:
            receiveConnectionReset(frame.payload)
        case .window:
            let increment = Int(windowIncrement(frame.payload))
            guard increment > 0 else { return fatal(.protocolError, "a WINDOW of 0") }
            guard connectionSendCredit + increment <= Limits.maxWindow else {
                return fatal(.flowControlError, "a connection WINDOW past 2^31-1")
            }
            connectionSendCredit += increment
        case .ping:
            break
        }
    }

    mutating func handleSessionMessage(_ message: Kernova_V2_SessionMessage) {
        guard let remoteHello else { return }
        switch message.message {
        case .hello:
            fatal(.protocolError, "a second Hello")
        case .peerState(let received):
            guard role == .host else { return fatal(.protocolError, "PeerState sent by the host") }
            let state = PeerSessionState(received: received)
            if remoteHello.claim.role == .sessionPeer, state.sessionID != remoteHello.state?.sessionID {
                return fatal(.protocolError, "a session peer's session_id changed")
            }
            remoteState = state
            emit(.peerStateChanged(state))
        case .capabilities(let update):
            remoteAdverts = receivedAdverts(update.features, remoteVersion: remoteHello.protocolVersion)
            emit(.remoteAdvertsChanged)
        case .policy(let update):
            guard role != .host else { return fatal(.protocolError, "PolicyUpdate sent by a peer") }
            let snapshot = PolicySnapshot(
                update.features.compactMap { entry in
                    guard FeatureDescriptor.lookup(entry.feature) != nil else { return nil }
                    return FeaturePolicyValue(
                        feature: entry.feature, version: entry.version, enabled: entry.enabled, params: entry.params)
                })
            currentPolicy = snapshot
            emit(.policyChanged(snapshot))
        case .updateAvailable(let available):
            guard role != .host else { return fatal(.protocolError, "UpdateAvailable sent by a peer") }
            let manifest = available.hasManifest ? UpdateManifestValue(received: available.manifest) : nil
            emit(.updateAvailable(manifest))
        case .extension(let bytes):
            if remoteHello.protocolVersion == configuration.protocolVersion,
                (try? Kernova_V2_SessionExtension(serializedBytes: bytes)) == nil
            {
                diagnose(.remoteViolation("a SessionExtension that does not decode"))
            }
        case nil:
            break
        }
    }

    mutating func receiveConnectionReset(_ payload: Data) {
        var error = WireError(receivedPayload: payload)
        if !(1...49).contains(error.code.rawValue) || !error.code.isAssigned {
            error.debugDetail = "code \(error.code.rawValue): \(error.debugDetail)"
            error.code = .internal
        }
        closeAllStreams(.connectionClosedByPeer(error), keepPendingResets: false)
        dropAllQueues()
        finish()
        emit(.closed(.closedByPeer(error)))
    }

    func windowIncrement(_ payload: Data) -> UInt32 {
        payload.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    // MARK: - Streams

    mutating func handleStreamFrame(_ frame: Frame) {
        let rawID = frame.streamID.rawValue
        switch frame.type {
        case .ping:
            return fatal(.protocolError, "PING on stream \(rawID)")
        case .open:
            return handleOpen(frame)
        case .data, .end, .reset, .window:
            break
        }
        let everOpened = isLocalParity(rawID) ? rawID <= highestLocalHandedOut : rawID <= highestRemoteOpened
        guard everOpened else { return fatal(.protocolError, "\(frame.type) on never-opened stream \(rawID)") }
        guard let index = index(of: frame.streamID) else { return handleLateFrame(frame) }
        guard streams[index].phase != .closed else {
            if frame.type == .reset { return receiveResetOnClosed(at: index) }
            return handleLateFrame(frame)
        }
        switch frame.type {
        case .data: receiveData(frame, at: index)
        case .end: receiveEnd(frame, at: index)
        case .reset: receiveStreamReset(frame, at: index)
        case .window: receiveStreamWindow(frame, at: index)
        case .open, .ping: break
        }
    }

    /// A RESET for a stream this side closed while its last frame, or its own
    /// RESET, waits to leave: a received RESET discards the queue all the same, so the record
    /// retires and frees its slot just as the far side's does.
    mutating func receiveResetOnClosed(at index: Int) {
        discardQueue(at: index)
        streams[index].pendingReset = nil
        retireIfDone(at: index)
    }

    /// A frame for a stream this side has closed: ignored, its raw bytes credited back.
    mutating func handleLateFrame(_ frame: Frame) {
        guard frame.type == .data, !frame.flags.contains(.message) else { return }
        let count = frame.payload.count
        guard count <= connectionReceiveRemaining else {
            return fatal(.flowControlError, "raw DATA beyond the connection's credit")
        }
        connectionReceiveRemaining -= count
        connectionUnreturned += count
        returnConnectionCredit()
    }

    mutating func handleOpen(_ frame: Frame) {
        let rawID = frame.streamID.rawValue
        guard !isLocalParity(rawID) else { return fatal(.protocolError, "OPEN \(rawID) has this side's parity") }
        guard rawID > highestRemoteOpened else {
            return fatal(.protocolError, "OPEN \(rawID) is not above \(highestRemoteOpened)")
        }
        highestRemoteOpened = rawID
        let id = frame.streamID
        // An honest opener still counts every stream this one does; twice the
        // limit can only be a far side ignoring it, whose refusals would queue unbounded.
        let counted = remoteSlotsCounted
        if counted >= 2 * Limits.maxConcurrentStreams {
            return fatal(.protocolError, "the far side holds \(counted) streams against a limit of 64")
        }
        guard let open = try? Kernova_V2_Open(serializedBytes: frame.payload) else {
            return refuse(id, nil, WireError(.malformedMessage, debugDetail: "the OPEN payload does not decode"))
        }
        guard let descriptor = descriptor(for: open.kind), !opensAsThisRole(descriptor) else {
            return refuse(id, nil, WireError(.unsupportedKind))
        }
        openBucket.refill(clock.raw)
        guard counted < Limits.maxConcurrentStreams, openBucket.take(1) else {
            return refuse(id, descriptor, WireError(.tooManyStreams))
        }
        if let feature = descriptor.feature, case .absent(let reason, _) = usability(feature) {
            return refuse(id, descriptor, WireError(.featureUnavailable, absence: reason))
        }
        guard descriptor.isValidOpenBody(open.body) else {
            return refuse(id, descriptor, WireError(.malformedMessage))
        }
        if let max = descriptor.maxPerConnection {
            let open = streams.count(where: {
                !$0.isLocal && $0.isAccepted && $0.kind == descriptor.kind && $0.phase != .closed
            })
            if open >= max { return refuse(id, descriptor, WireError(descriptor.duplicateCode)) }
        }
        var record = StreamRecord(
            id: id, descriptor: descriptor, isLocal: false, isAccepted: true, bulkTarget: policy.bulkReceiveTarget)
        raiseToBulkTarget(&record, viaQueue: false)
        record.wasWritable = sendPredicate(record)
        insert(record)
        emit(.opened(id, descriptor.kind, body: open.body), owner: descriptor.owner)
    }

    /// Answers a refused OPEN with RESET; the stream counts as closed at once and
    /// the machines never hear of it.
    mutating func refuse(_ id: StreamID, _ descriptor: StreamKindDescriptor?, _ error: WireError) {
        var record = StreamRecord(
            id: id, descriptor: descriptor ?? Self.refusedDescriptor, isLocal: false, isAccepted: false,
            bulkTarget: policy.bulkReceiveTarget)
        record.phase = .closed
        record.pendingReset = error
        insert(record)
    }

    static let refusedDescriptor = StreamKindDescriptor(
        kind: .unspecified, feature: nil, owner: nil, openerRole: .host, openerToAcceptor: .nothing,
        acceptorToOpener: .nothing, maxPerConnection: nil, isValidOpenBody: { _ in false })

    /// Raises a raw-DATA receive direction to the bulk target with one WINDOW.
    func raiseToBulkTarget(_ record: inout StreamRecord, viaQueue: Bool) {
        let raise = record.receiveTarget - Limits.initialStreamWindow
        guard raise > 0 else { return }
        record.receiveRemaining += raise
        if viaQueue {
            record.enqueue(.window(UInt32(raise)))
        } else {
            record.pendingWindow += raise
        }
    }

    mutating func receiveData(_ frame: Frame, at index: Int) {
        let count = frame.payload.count
        let isMessage = frame.flags.contains(.message)
        guard count <= streams[index].receiveRemaining else {
            return fatal(.flowControlError, "DATA beyond stream \(frame.streamID.rawValue)'s credit")
        }
        if !isMessage {
            guard count <= connectionReceiveRemaining else {
                return fatal(.flowControlError, "raw DATA beyond the connection's credit")
            }
            connectionReceiveRemaining -= count
        }
        streams[index].receiveRemaining -= count
        let expected = streams[index].receiving
        let violation: String?
        if streams[index].phase == .remoteEnded {
            violation = "DATA after END"
        } else if isMessage ? expected != .messages : expected != .rawData {
            violation = "\(isMessage ? "a message" : "raw DATA") the kind does not carry in this direction"
        } else {
            violation = nil
        }
        if let violation {
            if !isMessage {
                connectionUnreturned += count
                returnConnectionCredit()
            }
            diagnose(.remoteViolation(violation))
            return resetStream(at: index, WireError(.streamProtocolError, debugDetail: violation))
        }
        let owner = streams[index].owner
        if isMessage {
            streams[index].unreturned += count
            emit(.message(frame.streamID, frame.payload), owner: owner)
            returnStreamCredit(at: index)
        } else {
            streams[index].heldRaw += count
            connectionHeldRaw += count
            emit(.data(frame.streamID, frame.payload), owner: owner)
        }
    }

    mutating func receiveEnd(_ frame: Frame, at index: Int) {
        guard streams[index].phase != .remoteEnded else {
            diagnose(.remoteViolation("a second END"))
            return resetStream(at: index, WireError(.streamProtocolError, debugDetail: "a second END"))
        }
        let id = frame.streamID
        streams[index].remoteEndBody = frame.payload
        emit(.remoteEnded(id, body: frame.payload), owner: streams[index].owner)
        if streams[index].phase == .localEnded {
            closeStream(at: index, .completed(remoteEndBody: frame.payload))
        } else {
            streams[index].phase = .remoteEnded
            streams[index].pendingWindow = 0
        }
    }

    mutating func receiveStreamReset(_ frame: Frame, at index: Int) {
        var error = WireError(receivedPayload: frame.payload)
        let raw = error.code.rawValue
        let keeps = (50...99).contains(raw) || streams[index].descriptor.featureCodeRange?.contains(raw) == true
        if !keeps || !error.code.isAssigned {
            error.debugDetail = "code \(raw): \(error.debugDetail)"
            error.code = .streamProtocolError
        }
        closeStream(at: index, .resetByPeer(error), discardingQueue: true)
    }

    mutating func receiveStreamWindow(_ frame: Frame, at index: Int) {
        let increment = Int(windowIncrement(frame.payload))
        guard increment > 0 else { return fatal(.protocolError, "a WINDOW of 0") }
        guard streams[index].sendWindow + increment <= Limits.maxWindow else {
            return fatal(.flowControlError, "a stream WINDOW past 2^31-1")
        }
        streams[index].sendWindow += increment
        refreshWritable(at: index)
    }
}
