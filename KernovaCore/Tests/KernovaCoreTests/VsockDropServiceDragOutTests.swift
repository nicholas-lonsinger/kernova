import Foundation
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import Observation
import Testing
import UniformTypeIdentifiers

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The host side of dragging files out of a macOS guest: the offer it holds,
/// the take that withholds the press until the guest's catcher is the drag's
/// target, the item writes a Mac destination asks for, and the `DragComplete`
/// that tells the guest it is done.
///
/// The guest is a real guest-role endpoint over a socketpair, its data
/// connections dialled straight into the service, so both ends run the
/// shipping protocol code.
@Suite("VsockDropService drag-out", .caseScoped)
@MainActor
struct VsockDropServiceDragOutTests {
    private let scratch = TestScratchDirectory(prefix: "VsockDropServiceDragOutTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    // MARK: - Doubles

    /// What a take asked the display to do.
    enum DisplayCall: Equatable {
        case nudge(GuestDragNudge)
        case drag(CGPoint)
        case returnToExit
        case beginSession
        case release
        case resume
    }

    /// A display that records what the take asks of it.
    @MainActor
    final class RecordingDisplay: GuestDragDisplay {
        private(set) var calls: [DisplayCall] = []
        let changed = AsyncGate()

        var releaseCount: Int { calls.filter { $0 == .release }.count }

        func injectNudge(_ nudge: GuestDragNudge) { record(.nudge(nudge)) }
        func injectDrag(at point: CGPoint) { record(.drag(point)) }
        func returnToExitPoint() { record(.returnToExit) }
        func injectRelease() { record(.release) }
        func resumeForwarding() { record(.resume) }

        func beginHostSession(carrying take: any GuestDragTaking) -> Bool {
            record(.beginSession)
            return true
        }

        private func record(_ call: DisplayCall) {
            calls.append(call)
            changed.notify()
        }
    }

    /// The condition a take holds under, standing in for the VM's status.
    @MainActor
    @Observable
    final class RunningFlag {
        var isRunning = true
    }

    /// Holds a write's landing on its writing thread until the test releases
    /// it, recording the staged copy the landing moves.
    final class HeldLanding: Sendable {
        private let staged = Locked<URL??>(nil)
        private let gate = AsyncGate()
        private let held = DispatchSemaphore(value: 0)

        /// The seam to hand the take.
        var body: @Sendable (URL?) -> Void {
            { [self] url in
                staged.withLock { $0 = .some(url) }
                gate.notify()
                held.wait()
            }
        }

        /// The staged copy, once a landing has begun.
        func began(isolation: isolated (any Actor)? = #isolation) async throws -> URL {
            try await gate.wait(isolation: isolation) { staged.withLock { $0 } != nil }
            return try #require(staged.withLock { $0 } ?? nil)
        }

        /// Lets the held landing go on.
        func release() { held.signal() }
    }

    /// How one item write ended, as a destination would see it.
    enum WriteResult: Equatable, Sendable {
        case landed
        case cancelled
        case failed(ClipboardTransferFailure)
        case other(String)
    }

    // MARK: - Harness

    @MainActor
    final class Harness {
        let service: VsockDropService
        let guest: ClipboardEndpoint
        let guestRecorder = EndpointRecorder()
        /// This VM's transfer report, as every surface reads it.
        let reports = ClipboardTransferReports()
        let guestReports = ClipboardTransferReports()
        /// The hand-off deadline's clock: it passes only when a test releases it.
        let clock = GatedEngineClock()
        let display = RecordingDisplay()
        let running = RunningFlag()
        /// The guest's data connections, held back from the service for a
        /// harness whose pulls park.
        let parked = DialledDataConnections()
        let guestChannel: VsockChannel
        private let hostChannel: VsockChannel
        private let hostStagingRoot = TestStagingRoot()
        private let guestStaging: ClipboardFileStaging

        /// `progressRevealDelay` and `progressIdleGap` are the host readout's.
        init(
            parksPulls: Bool = false, progressRevealDelay: TimeInterval = 0,
            progressIdleGap: TimeInterval = 0
        ) throws {
            let (hostFd, guestFd) = try makeRawSocketPair()
            hostChannel = VsockChannel(fileDescriptor: hostFd)
            guestChannel = VsockChannel(fileDescriptor: guestFd)
            hostChannel.start()
            guestChannel.start()
            let service = VsockDropService(
                channel: hostChannel, label: "Drag VM", reporter: reports.reporter,
                stagingRoot: hostStagingRoot.root, stagingKey: "drag-vm",
                progressRevealDelay: progressRevealDelay, progressIdleGap: progressIdleGap,
                clock: clock)
            self.service = service
            guestStaging = ClipboardFileStaging(label: "guest", root: TestStagingRoot().root)
            let parked = self.parked
            let dialer: @Sendable (UInt32) throws -> Int32
            if parksPulls {
                dialer = parked.dialer
            } else {
                dialer = { _ in
                    // The far end goes straight to the service's accept path —
                    // the in-process stand-in for the drop data listener.
                    let (near, far) = try makeRawSocketPair()
                    service.acceptDataConnection(fd: far)
                    return near
                }
            }
            guest = ClipboardEndpoint(
                channel: guestChannel,
                configuration: ClipboardEndpoint.Configuration(
                    role: .guest, kind: .drop, label: "guest", peerName: "Mac",
                    maxPasteBytes: { .max }, staging: guestStaging, progressRevealDelay: 0,
                    progressIdleGap: 0, dataLink: .dials(port: 0, connect: dialer)),
                reporter: guestReports.reporter)
            guest.delegate = guestRecorder
            service.start()
            guest.start()
        }

        func tearDown() {
            guest.stop()
            service.stop()
            guestChannel.close()
            parked.closeAll()
            guestStaging.sweep()
        }

        /// Offers `urls` from the guest as one drag, reading nothing inside a
        /// folder as the agent does, and waits for the host to hold it.
        func offer(_ urls: [URL]) async throws -> ClipboardInboundDrag {
            let intake = ClipboardPasteboardReader.resolve(filesAt: urls, sizeOf: nil)
            let outcome = guest.offer(ClipboardContent(representations: intake.representations))
            guard case .sent(let generation) = outcome else {
                throw TestFailure("The guest's drag was not offered: \(outcome)")
            }
            try await waitForChange { self.service.guestDrag?.generation == generation }
            return try #require(service.guestDrag)
        }

        /// Takes `drag` over for the recording display.
        func take(_ drag: ClipboardInboundDrag) throws -> GuestDragTake {
            let running = self.running
            let take = service.takeGuestDrag(
                generation: drag.generation, display: display, while: { running.isRunning })
            return try #require(take)
        }

        /// Offers `urls` and takes the drag, waiting for the guest to hear
        /// `DragTake`, then — unless `sendingSizes` is false — sends its
        /// folders' sizes as the agent does.
        func offerAndTake(_ urls: [URL], sendingSizes: Bool = true) async throws -> GuestDragTake {
            let take = try take(try await offer(urls))
            try await guestRecorder.wait { self.guestRecorder.takes.contains(take.generation) }
            if sendingSizes { sendSizes(of: take) }
            return take
        }

        /// Sends the sizes of `take`'s folders, as the agent does once it has
        /// measured them.
        func sendSizes(of take: GuestDragTake) {
            let folders = guest.outboundContent(generation: take.generation)?.directorySources ?? [:]
            guard !folders.isEmpty else { return }
            guest.sendDragSizes(
                generation: take.generation,
                folderByteCounts: folders.mapValues { ClipboardArchive.estimatedByteCount(at: $0) })
        }

        /// Reports one hand-off step from the guest and waits for the take to
        /// reach `phase`.
        func handOff(
            _ step: ClipboardDragHandOffStep, for take: GuestDragTake,
            reaching phase: GuestDragTake.Phase
        ) async throws {
            guest.sendDragHandOff(generation: take.generation, step: step)
            try await waitForChange { take.phase == phase }
        }

        /// Takes a drag over and drives it to its catcher's target: armed, then
        /// targeted.
        func readyTake(_ urls: [URL], sendingSizes: Bool = true) async throws -> GuestDragTake {
            let take = try await offerAndTake(urls, sendingSizes: sendingSizes)
            try await handOff(.armed, for: take, reaching: .handingOff(armed: true))
            try await handOff(.targeted, for: take, reaching: .ready)
            return take
        }

        /// A ready take whose next withheld drag began the Mac session.
        func carriedTake(_ urls: [URL], sendingSizes: Bool = true) async throws -> GuestDragTake {
            let take = try await readyTake(urls, sendingSizes: sendingSizes)
            take.withheldDrag()
            #expect(take.phase == .carried(.outside(targeted: true)))
            return take
        }

        /// Takes a drag over and drives it to the guest's catch: a Mac session
        /// carries it, ends with `dropped`, the guest's button is released onto
        /// its catcher, and the guest reports the catch.
        func releasedTake(_ urls: [URL], dropped: Bool = true) async throws -> GuestDragTake {
            let take = try await carriedTake(urls)
            take.hostSessionEnded(dropped: dropped)
            #expect(take.phase == .released(at: .catcher))
            guest.sendDragHandOff(generation: take.generation, step: .caught)
            return take
        }

        /// A carried take whose session came back over the display at `point`.
        func insideTake(_ urls: [URL], at point: CGPoint) async throws -> GuestDragTake {
            let take = try await carriedTake(urls)
            #expect(take.hostSession(over: display, at: point))
            #expect(take.phase == .carried(.inside))
            return take
        }

        /// Waits until the guest has heard `count` `DragCatcher` frames.
        func waitForCatcherChanges(_ count: Int) async throws {
            try await guestRecorder.wait { self.guestRecorder.catcherChanges.count >= count }
        }

        /// Reports one hand-off step from the guest and waits for the display
        /// to have recorded `call` `times` times in all.
        func handOff(
            _ step: ClipboardDragHandOffStep, for take: GuestDragTake, until call: DisplayCall,
            times: Int
        ) async throws {
            guest.sendDragHandOff(generation: take.generation, step: step)
            try await display.changed.wait { self.display.calls.filter { $0 == call }.count >= times }
        }

        /// Waits for the take's `ordinal`th hand-off deadline to start sleeping,
        /// and lets it pass.
        func passDeadline(_ ordinal: Int = 1) async throws {
            let seconds = GuestDragTake.handOffDeadline
            try await clock.sleepRequested.wait {
                self.clock.requestedSeconds.filter { $0 == seconds }.count >= ordinal
                    && self.clock.parked.contains { $0.seconds == seconds }
            }
            let deadline = try #require(
                clock.parked.filter { $0.seconds == seconds }.max { $0.id < $1.id })
            clock.release(deadline)
        }

        /// Waits until the guest has heard `DragComplete` for `generation`.
        func waitForComplete(_ generation: UInt64) async throws {
            try await guestRecorder.wait { self.guestRecorder.completedDrags.contains(generation) }
        }

        /// Waits until the display has recorded `call`.
        func waitForDisplay(_ call: DisplayCall) async throws {
            try await display.changed.wait { self.display.calls.contains(call) }
        }

        /// Sends one host→guest frame after everything already sent, and waits
        /// for the guest to receive it — so a frame the host would have sent
        /// before it has arrived by the time this returns.
        func hostToGuestBarrier(scratch: URL) async throws {
            let file = scratch.appendingPathComponent("barrier-\(UUID().uuidString).txt")
            try Data("barrier".utf8).write(to: file)
            let before = guestRecorder.offers.count
            #expect(service.startDrop(urls: [file]))
            try await guestRecorder.wait { self.guestRecorder.offers.count > before }
        }

        /// Writes item `index` of `take` to `destination` the way a promise
        /// provider's operation queue does.
        func write(_ take: GuestDragTake, item index: Int, to destination: URL) async -> WriteResult {
            await offCooperativePool {
                do {
                    try take.writeItem(at: index, to: destination)
                    return .landed
                } catch let error as GuestDragWriteError {
                    guard case .failed(let failure) = error else { return .other("\(error)") }
                    return .failed(failure)
                } catch let error as CocoaError where error.code == .userCancelled {
                    return .cancelled
                } catch {
                    return .other("\(error)")
                }
            }
        }
    }

    // MARK: - Fixtures

    private func makeFile(named name: String, contents: String) throws -> URL {
        let url = scratch.url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeFolder(named name: String, files: [String: String]) throws -> URL {
        let url = scratch.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (file, contents) in files {
            try Data(contents.utf8).write(to: url.appendingPathComponent(file))
        }
        return url
    }

    /// A directory nothing has written into, standing in for where a Mac
    /// destination asks for the files.
    private func makeDestination() throws -> URL {
        let url = scratch.url.appendingPathComponent("Destination-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The offer

    @Test("a guest drag is held as the offer the display may take, with its items")
    func guestDragIsHeld() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let file = try makeFile(named: "notes.txt", contents: "notes")

        let drag = try await harness.offer([file])

        #expect(drag.items.map(\.filename) == ["notes.txt"])
        #expect(drag.items.allSatisfy { !$0.isDirectory })
    }

    @Test("the guest withdrawing its drag clears the offer")
    func withdrawalClearsTheOffer() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let drag = try await harness.offer([try makeFile(named: "a.txt", contents: "a")])

        #expect(harness.guest.withdraw(generation: drag.generation))

        try await waitForChange { harness.service.guestDrag == nil }
    }

    @Test("a new press on the display clears the offer the last press left")
    func newPressClearsTheOffer() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        _ = try await harness.offer([try makeFile(named: "a.txt", contents: "a")])

        harness.service.displayPressBegan()

        #expect(harness.service.guestDrag == nil)
    }

    @Test("the channel ending clears the offer")
    func channelEndClearsTheOffer() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        _ = try await harness.offer([try makeFile(named: "a.txt", contents: "a")])

        harness.guestChannel.close()

        try await waitForChange { !harness.service.isConnected }
        #expect(harness.service.guestDrag == nil)
    }

    // MARK: - Taking over

    @Test("a take sends DragTake and leaves no offer to take again")
    func takeSendsDragTake() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let drag = try await harness.offer([try makeFile(named: "a.txt", contents: "a")])

        let take = try harness.take(drag)

        try await harness.guestRecorder.wait { harness.guestRecorder.takes == [drag.generation] }
        #expect(take.phase == .handingOff(armed: false))
        #expect(harness.service.guestDrag == nil)
        let again = harness.service.takeGuestDrag(
            generation: drag.generation, display: harness.display, while: { true })
        #expect(again == nil)
        // Nothing is injected until the guest's catcher is up.
        #expect(harness.display.calls.isEmpty)
    }

    @Test("a take names only the drag on offer now")
    func staleGenerationIsNotTaken() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let drag = try await harness.offer([try makeFile(named: "a.txt", contents: "a")])

        let stale = harness.service.takeGuestDrag(
            generation: drag.generation + 1, display: harness.display, while: { true })
        #expect(stale == nil)
        #expect(harness.service.guestDrag == drag)
    }

    @Test("ARMED nudges once, and each withheld drag before TARGETED nudges again, alternating")
    func armedNudgesAlternately() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.offerAndTake([try makeFile(named: "a.txt", contents: "a")])

        // Before the catcher is up, motion has nothing to re-target.
        take.withheldDrag()
        #expect(harness.display.calls.isEmpty)

        try await harness.handOff(.armed, for: take, reaching: .handingOff(armed: true))
        #expect(harness.display.calls == [.nudge(.exitPoint)])

        take.withheldDrag()
        take.withheldDrag()
        #expect(harness.display.calls == [.nudge(.exitPoint), .nudge(.offset), .nudge(.exitPoint)])
    }

    @Test("TARGETED readies the take, and the next withheld drag begins the session without a release")
    func targetedBeginsTheSessionWithoutARelease() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.offerAndTake([try makeFile(named: "a.txt", contents: "a")])
        try await harness.handOff(.armed, for: take, reaching: .handingOff(armed: true))

        try await harness.handOff(.targeted, for: take, reaching: .ready)
        #expect(harness.display.calls == [.nudge(.exitPoint)])

        take.withheldDrag()

        #expect(harness.display.calls == [.nudge(.exitPoint), .beginSession])
        #expect(take.phase == .carried(.outside(targeted: true)))
        // The guest's drag is still live, so nothing tells its catcher to go.
        try await harness.hostToGuestBarrier(scratch: scratch.url)
        #expect(harness.guestRecorder.completedDrags.isEmpty)
    }

    @Test("the button coming up once the take is ready releases without a session")
    func mouseUpWhileReadyReleasesWithoutASession() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.offerAndTake([try makeFile(named: "a.txt", contents: "a")])
        try await harness.handOff(.armed, for: take, reaching: .handingOff(armed: true))
        try await harness.handOff(.targeted, for: take, reaching: .ready)

        take.withheldMouseUp()

        #expect(harness.display.calls == [.nudge(.exitPoint), .release])
        #expect(take.phase == .released(at: .catcher))
    }

    @Test("a released take never releases again")
    func releasesAtMostOnce() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.carriedTake([try makeFile(named: "a.txt", contents: "a")])
        take.hostSessionEnded(dropped: false)

        take.withheldDrag()
        take.withheldMouseUp()
        take.displayAbandoned()
        #expect(!take.hostSession(over: harness.display, at: CGPoint(x: 5, y: 5)))
        #expect(!take.hostSessionDropped(on: harness.display, at: CGPoint(x: 5, y: 5)))
        harness.guest.sendDragHandOff(generation: take.generation, step: .targeted)
        harness.guest.sendDragHandOff(generation: take.generation, step: .caught)
        take.hostSessionEnded(dropped: false)
        try await harness.waitForComplete(take.generation)

        #expect(harness.display.releaseCount == 1)
        #expect(!harness.display.calls.contains(.resume))
    }

    // MARK: - Failing before the release

    /// Every way a take can fail before the guest's catcher is its target.
    enum EarlyFailure: String, CaseIterable, Sendable {
        case guestFailed
        case guestCaught
        case guestWithdrew
        case buttonUp
        case deadline
        case vmStopped
        case channelLost
    }

    @Test(
        "every failure before TARGETED resumes forwarding, tells a live guest, and never releases",
        arguments: EarlyFailure.allCases)
    func earlyFailureAbandons(_ failure: EarlyFailure) async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.offerAndTake([try makeFile(named: "a.txt", contents: "a")])
        try await harness.handOff(.armed, for: take, reaching: .handingOff(armed: true))

        switch failure {
        case .guestFailed:
            harness.guest.sendDragHandOff(
                generation: take.generation, step: .failed(.dragTakeRefused, message: "refused"))
        case .guestCaught:
            harness.guest.sendDragHandOff(generation: take.generation, step: .caught)
        case .guestWithdrew:
            #expect(harness.guest.withdraw(generation: take.generation))
        case .buttonUp:
            take.withheldMouseUp()
        case .deadline:
            try await harness.passDeadline()
        case .vmStopped:
            harness.running.isRunning = false
        case .channelLost:
            harness.guestChannel.close()
        }

        try await harness.waitForDisplay(.resume)
        #expect(take.phase == .abandoned)
        // The guest pointer goes back to where the drag left the display
        // before the press is the guest's again.
        #expect(harness.display.calls.suffix(2) == [.returnToExit, .resume])
        #expect(harness.display.releaseCount == 0)
        #expect(!harness.display.calls.contains(.beginSession))
        if failure != .channelLost {
            try await harness.waitForComplete(take.generation)
        }
        // Whatever the guest reports afterwards, an abandoned take stays down.
        take.withheldDrag()
        take.withheldMouseUp()
        #expect(harness.display.releaseCount == 0)
    }

    @Test(
        "a failure after TARGETED but before the release also abandons rather than releasing",
        arguments: [EarlyFailure.guestFailed, .guestCaught, .guestWithdrew, .vmStopped])
    func readyFailureAbandons(_ failure: EarlyFailure) async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.offerAndTake([try makeFile(named: "a.txt", contents: "a")])
        try await harness.handOff(.armed, for: take, reaching: .handingOff(armed: true))
        try await harness.handOff(.targeted, for: take, reaching: .ready)

        switch failure {
        case .guestFailed:
            harness.guest.sendDragHandOff(
                generation: take.generation, step: .failed(.dragTakeFailed, message: "exited"))
        case .guestCaught:
            harness.guest.sendDragHandOff(generation: take.generation, step: .caught)
        case .guestWithdrew:
            #expect(harness.guest.withdraw(generation: take.generation))
        case .vmStopped:
            harness.running.isRunning = false
        case .buttonUp, .deadline, .channelLost:
            Issue.record("Not a ready-state case")
        }

        try await harness.waitForDisplay(.resume)
        #expect(harness.display.calls.suffix(2) == [.returnToExit, .resume])
        try await harness.waitForComplete(take.generation)
        #expect(harness.display.releaseCount == 0)
        take.withheldDrag()
        #expect(harness.display.releaseCount == 0)
    }

    /// Where the hand-off stands when the pointer comes back over the display.
    enum ReturnPoint: String, CaseIterable, Sendable {
        case beforeArmed
        case armed
        case ready
    }

    @Test(
        "the pointer coming back before the release abandons, resumes forwarding, completes, and never releases",
        arguments: ReturnPoint.allCases)
    func pointerReturnAbandons(_ point: ReturnPoint) async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.offerAndTake([try makeFile(named: "a.txt", contents: "a")])
        if point != .beforeArmed {
            try await harness.handOff(.armed, for: take, reaching: .handingOff(armed: true))
        }
        if point == .ready {
            try await harness.handOff(.targeted, for: take, reaching: .ready)
        }

        take.pointerReturned()

        #expect(take.phase == .abandoned)
        #expect(harness.display.calls.suffix(2) == [.returnToExit, .resume])
        #expect(harness.display.releaseCount == 0)
        #expect(!harness.display.calls.contains(.beginSession))
        try await harness.waitForComplete(take.generation)
        take.withheldDrag()
        take.withheldMouseUp()
        #expect(harness.display.releaseCount == 0)
    }

    @Test("the pointer coming back after the release changes nothing")
    func pointerReturnAfterTheReleaseIsInert() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.releasedTake([try makeFile(named: "a.txt", contents: "a")])

        take.pointerReturned()

        #expect(take.phase == .released(at: .catcher))
        #expect(!harness.display.calls.contains(.resume))
    }

    @Test("a hand-off deadline that passes after TARGETED does nothing")
    func deadlineAfterTargetedIsInert() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.offerAndTake([try makeFile(named: "a.txt", contents: "a")])
        try await harness.handOff(.armed, for: take, reaching: .handingOff(armed: true))
        try await harness.handOff(.targeted, for: take, reaching: .ready)

        // The deadline's task was cancelled, so its sleep left the clock.
        try await harness.clock.parkedChanged.wait {
            !harness.clock.parked.contains { $0.seconds == GuestDragTake.handOffDeadline }
        }
        #expect(take.phase == .ready)
        #expect(!harness.display.calls.contains(.resume))
    }

    // MARK: - Carried by the Mac session

    @Test("the session coming back over its display stands the catcher down and moves the guest pointer with it")
    func sessionOverTheDisplayStandsTheCatcherDown() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.carriedTake([try makeFile(named: "a.txt", contents: "a")])
        #expect(!take.sessionOverDisplay)
        var changes: [Bool] = []
        take.sessionOverDisplayChanged = { changes.append($0) }

        #expect(take.hostSession(over: harness.display, at: CGPoint(x: 10, y: 20)))
        #expect(changes == [true])
        #expect(take.hostSession(over: harness.display, at: CGPoint(x: 12, y: 22)))

        #expect(take.phase == .carried(.inside))
        #expect(take.sessionOverDisplay)
        #expect(changes == [true])
        #expect(
            Array(harness.display.calls.suffix(2)) == [
                .drag(CGPoint(x: 10, y: 20)), .drag(CGPoint(x: 12, y: 22)),
            ])
        try await harness.waitForCatcherChanges(1)
        #expect(
            harness.guestRecorder.catcherChanges == [.init(generation: take.generation, shown: false)])
        #expect(harness.display.releaseCount == 0)
    }

    @Test("another display of the same VM never carries the session")
    func anotherDisplayIsRefused() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.carriedTake([try makeFile(named: "a.txt", contents: "a")])
        let other = RecordingDisplay()

        #expect(!take.hostSession(over: other, at: CGPoint(x: 10, y: 20)))
        #expect(!take.hostSessionDropped(on: other, at: CGPoint(x: 10, y: 20)))

        #expect(take.phase == .carried(.outside(targeted: true)))
        #expect(other.calls.isEmpty)
    }

    @Test("a drop on its display releases there, the guest's own drop, and completes without a catch")
    func dropOnTheDisplayReleasesAtTheDropPoint() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.insideTake(
            [try makeFile(named: "a.txt", contents: "a")], at: CGPoint(x: 10, y: 20))
        var changes: [Bool] = []
        take.sessionOverDisplayChanged = { changes.append($0) }

        #expect(take.hostSessionDropped(on: harness.display, at: CGPoint(x: 30, y: 40)))

        #expect(take.phase == .released(at: .dropPoint))
        #expect(changes == [false])
        #expect(Array(harness.display.calls.suffix(2)) == [.drag(CGPoint(x: 30, y: 40)), .release])
        take.hostSessionEnded(dropped: true)
        // No destination asks for the items, and the catcher is down.
        try await harness.waitForComplete(take.generation)
        #expect(harness.display.releaseCount == 1)
        let destination = try makeDestination().appendingPathComponent("a.txt")
        #expect(await harness.write(take, item: 0, to: destination) == .failed(.transferFailed))
    }

    @Test("the session leaving its display shows the catcher again, nudges on ARMED, and TARGETED re-targets it")
    func sessionLeavingShowsTheCatcherAgain() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.insideTake(
            [try makeFile(named: "a.txt", contents: "a")], at: CGPoint(x: 10, y: 20))

        var changes: [Bool] = []
        take.sessionOverDisplayChanged = { changes.append($0) }

        take.hostSessionLeft(harness.display)

        #expect(take.phase == .carried(.outside(targeted: false)))
        #expect(!take.sessionOverDisplay)
        #expect(changes == [false])
        try await harness.waitForCatcherChanges(2)
        #expect(harness.guestRecorder.catcherChanges.last == .init(generation: take.generation, shown: true))
        // A target reported for the showing that was stood down says nothing
        // about the one shown now.
        harness.guest.sendDragHandOff(generation: take.generation, step: .targeted)
        try await harness.handOff(.armed, for: take, until: .nudge(.offset), times: 1)
        #expect(take.phase == .carried(.outside(targeted: false)))
        // The user's own motion re-nudges until the catcher is the target.
        take.hostSessionMoved()
        #expect(harness.display.calls.last == .nudge(.exitPoint))

        try await harness.handOff(.targeted, for: take, reaching: .carried(.outside(targeted: true)))
        let nudges = harness.display.calls.count
        take.hostSessionMoved()
        #expect(harness.display.calls.count == nudges)

        take.hostSessionEnded(dropped: true)
        #expect(take.phase == .released(at: .catcher))
        #expect(harness.display.calls.last == .release)
    }

    @Test("a session that ends untargeted waits for TARGETED, then releases onto the catcher")
    func untargetedEndWaitsForTheTarget() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.insideTake(
            [try makeFile(named: "a.txt", contents: "a")], at: CGPoint(x: 10, y: 20))
        take.hostSessionLeft(harness.display)

        take.hostSessionEnded(dropped: true)

        #expect(take.phase == .carried(.ended))
        #expect(harness.display.releaseCount == 0)
        try await harness.handOff(.armed, for: take, until: .nudge(.offset), times: 1)
        harness.guest.sendDragHandOff(generation: take.generation, step: .targeted)
        try await harness.waitForDisplay(.release)
        #expect(take.phase == .released(at: .catcher))
        #expect(!harness.display.calls.contains(.returnToExit))
    }

    @Test("a session cancelled over its display shows the catcher again and waits for it")
    func cancelOverTheDisplayWaitsForTheCatcher() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.insideTake(
            [try makeFile(named: "a.txt", contents: "a")], at: CGPoint(x: 10, y: 20))

        take.hostSessionEnded(dropped: false)

        #expect(take.phase == .carried(.ended))
        try await harness.waitForCatcherChanges(2)
        #expect(harness.guestRecorder.catcherChanges.last == .init(generation: take.generation, shown: true))
        try await harness.handOff(.armed, for: take, until: .nudge(.offset), times: 1)
        harness.guest.sendDragHandOff(generation: take.generation, step: .targeted)
        try await harness.waitForDisplay(.release)
        #expect(take.phase == .released(at: .catcher))
    }

    /// Every way the catcher can fail to take a drag whose session ended.
    enum LateFailure: String, CaseIterable, Sendable {
        case deadline
        case guestFailed
        case channelLost
    }

    @Test(
        "a session that ends untargeted and loses its catcher releases where the drag left the display",
        arguments: LateFailure.allCases)
    func lostCatcherReleasesAtTheExitPoint(_ failure: LateFailure) async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.insideTake(
            [try makeFile(named: "a.txt", contents: "a")], at: CGPoint(x: 10, y: 20))
        take.hostSessionLeft(harness.display)
        take.hostSessionEnded(dropped: true)

        switch failure {
        case .deadline:
            try await harness.passDeadline(2)
        case .guestFailed:
            harness.guest.sendDragHandOff(
                generation: take.generation, step: .failed(.dragTakeFailed, message: "gone"))
        case .channelLost:
            harness.guestChannel.close()
        }

        try await harness.waitForDisplay(.release)
        #expect(take.phase == .released(at: .exitPoint))
        #expect(Array(harness.display.calls.suffix(2)) == [.returnToExit, .release])
        #expect(!harness.display.calls.contains(.resume))
    }

    @Test("a catcher lost while the session is still out releases at the exit point when it ends")
    func catcherLostMidSessionReleasesAtTheExitPoint() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.carriedTake([try makeFile(named: "a.txt", contents: "a")])
        // A refusal after TARGETED, which the guest reports once and for good.
        try await harness.handOff(
            .failed(.dragTakeRefused, message: "no copy"), for: take,
            reaching: .carried(.outside(targeted: false)))

        take.hostSessionEnded(dropped: true)

        #expect(take.phase == .released(at: .exitPoint))
        #expect(Array(harness.display.calls.suffix(2)) == [.returnToExit, .release])
    }

    @Test("the VM stopping under the session injects nothing")
    func vmStoppingUnderTheSessionInjectsNothing() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.insideTake(
            [try makeFile(named: "a.txt", contents: "a")], at: CGPoint(x: 10, y: 20))
        let calls = harness.display.calls.count
        var changes: [Bool] = []
        take.sessionOverDisplayChanged = { changes.append($0) }

        harness.running.isRunning = false

        try await waitForChange { take.phase == .unreleased }
        #expect(changes == [false])
        take.hostSessionLeft(harness.display)
        take.hostSessionEnded(dropped: false)
        #expect(changes == [false])
        #expect(harness.display.calls.count == calls)
        try await harness.waitForComplete(take.generation)
    }

    @Test("a destination asking while the guest's drag is still live is written, before any catch")
    func writesDoNotWaitForTheCatch() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.carriedTake([try makeFile(named: "a.txt", contents: "a")])
        let destination = try makeDestination().appendingPathComponent("a.txt")

        #expect(await harness.write(take, item: 0, to: destination) == .landed)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "a")
        // The guest's drag is still live, so nothing completes it yet.
        try await harness.hostToGuestBarrier(scratch: scratch.url)
        #expect(harness.guestRecorder.completedDrags.isEmpty)

        take.hostSessionEnded(dropped: true)
        harness.guest.sendDragHandOff(generation: take.generation, step: .caught)
        try await harness.waitForComplete(take.generation)
    }

    @Test("a take with no Mac session refuses every write")
    func noSessionNoWrites() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.readyTake([try makeFile(named: "a.txt", contents: "a")])
        let destination = try makeDestination().appendingPathComponent("a.txt")

        #expect(await harness.write(take, item: 0, to: destination) == .failed(.transferFailed))
    }

    // MARK: - Garbage collection

    @Test("a release without a session completes the drag only once the guest reports its catch")
    func completionWaitsForTheCatch() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.offerAndTake([try makeFile(named: "a.txt", contents: "a")])
        try await harness.handOff(.armed, for: take, reaching: .handingOff(armed: true))
        try await harness.handOff(.targeted, for: take, reaching: .ready)
        take.withheldMouseUp()

        // A DragComplete overtaking the injected release would have the
        // catcher refuse the release rather than catch it.
        try await harness.hostToGuestBarrier(scratch: scratch.url)
        #expect(harness.guestRecorder.completedDrags.isEmpty)

        harness.guest.sendDragHandOff(generation: take.generation, step: .caught)
        try await harness.waitForComplete(take.generation)
    }

    @Test("a session that ends with nothing dropped completes the drag once caught")
    func emptyDropCompletes() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.carriedTake([try makeFile(named: "a.txt", contents: "a")])
        take.hostSessionEnded(dropped: false)

        try await harness.hostToGuestBarrier(scratch: scratch.url)
        #expect(harness.guestRecorder.completedDrags.isEmpty)

        harness.guest.sendDragHandOff(generation: take.generation, step: .caught)

        try await harness.waitForComplete(take.generation)
    }

    @Test("a session that a destination took completes the drag only once every item is written")
    func acceptedDropWaitsForTheWrites() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.releasedTake([try makeFile(named: "a.txt", contents: "a")])

        try await harness.hostToGuestBarrier(scratch: scratch.url)
        #expect(harness.guestRecorder.completedDrags.isEmpty)

        let destination = try makeDestination().appendingPathComponent("a.txt")
        #expect(await harness.write(take, item: 0, to: destination) == .landed)

        try await harness.waitForComplete(take.generation)
    }

    @Test("the next take completes one before it whose session dropped nothing, caught or not")
    func supersessionCompletes() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let first = try await harness.offerAndTake([try makeFile(named: "a.txt", contents: "a")])
        try await harness.handOff(.armed, for: first, reaching: .handingOff(armed: true))
        try await harness.handOff(.targeted, for: first, reaching: .ready)
        first.withheldDrag()
        first.hostSessionEnded(dropped: false)
        #expect(first.phase == .released(at: .catcher))
        // Uncaught, so it is still waiting for its guest drag to end.
        try await harness.hostToGuestBarrier(scratch: scratch.url)
        #expect(harness.guestRecorder.completedDrags.isEmpty)

        _ = try await harness.offerAndTake([try makeFile(named: "b.txt", contents: "b")])

        try await harness.waitForComplete(first.generation)
    }

    @Test("a superseded take still writes what its destination asks for, then completes")
    func supersededTakeKeepsWriting() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let first = try await harness.releasedTake([
            try makeFile(named: "a.txt", contents: "a"), try makeFile(named: "b.txt", contents: "b"),
        ])
        let destination = try makeDestination()
        #expect(
            await harness.write(first, item: 0, to: destination.appendingPathComponent("a.txt"))
                == .landed)

        _ = try await harness.offerAndTake([try makeFile(named: "c.txt", contents: "c")])
        try await harness.hostToGuestBarrier(scratch: scratch.url)
        #expect(!harness.guestRecorder.completedDrags.contains(first.generation))

        let queued = destination.appendingPathComponent("b.txt")
        #expect(await harness.write(first, item: 1, to: queued) == .landed)
        #expect(try String(contentsOf: queued, encoding: .utf8) == "b")
        try await harness.waitForComplete(first.generation)
    }

    @Test("a take superseded mid-write lands that write before it completes")
    func supersessionWaitsForTheWriteInFlight() async throws {
        let harness = try Harness(parksPulls: true)
        defer { harness.tearDown() }
        let first = try await harness.releasedTake([try makeFile(named: "a.txt", contents: "a")])
        let destination = try makeDestination().appendingPathComponent("a.txt")
        let write = Task { await harness.write(first, item: 0, to: destination) }
        let parked = try await harness.parked.next()

        _ = try await harness.offerAndTake([try makeFile(named: "b.txt", contents: "b")])
        try await harness.hostToGuestBarrier(scratch: scratch.url)
        #expect(!harness.guestRecorder.completedDrags.contains(first.generation))

        // A duplicate, so the harness's teardown still closes the one it holds.
        harness.service.acceptDataConnection(fd: dup(parked))

        #expect(await write.value == .landed)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "a")
        try await harness.waitForComplete(first.generation)
    }

    // MARK: - Writing items

    @Test("later drags' pulls leave an earlier drag's staging alone while its write is in flight")
    func concurrentDragsKeepTheirStaging() async throws {
        let harness = try Harness(parksPulls: true)
        defer { harness.tearDown() }
        let destination = try makeDestination()
        let first = try await harness.releasedTake([try makeFile(named: "a.txt", contents: "a")])
        first.hostSessionEnded(dropped: true)
        let firstWrite = Task {
            await harness.write(first, item: 0, to: destination.appendingPathComponent("a.txt"))
        }
        let firstPull = try await harness.parked.next()
        // Stands in for what the first drag's pull has staged so far.
        let staged = try harness.service.dragStagingForTesting.reserveScratchDirectory(
            generation: first.generation)

        // Past the newest-generations window a clipboard's staging keeps, each
        // still live: its second item is never asked for.
        for name in ["b", "c", "d"] {
            let take = try await harness.releasedTake([
                try makeFile(named: "\(name).txt", contents: name),
                try makeFile(named: "\(name)-more.txt", contents: name),
            ])
            take.hostSessionEnded(dropped: true)
            let target = destination.appendingPathComponent("\(name).txt")
            let write = Task { await harness.write(take, item: 0, to: target) }
            // A duplicate, so the harness's teardown still closes the one it holds.
            harness.service.acceptDataConnection(fd: dup(try await harness.parked.next()))
            #expect(await write.value == .landed)
        }

        #expect(FileManager.default.fileExists(atPath: staged.path))
        harness.service.acceptDataConnection(fd: dup(firstPull))
        #expect(await firstWrite.value == .landed)
        #expect(
            try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8)
                == "a")
    }

    @Test("the channel ending leaves a drag's staging to the landing in flight, whose end frees it")
    func channelEndLeavesStagingToTheLandingInFlight() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.releasedTake([try makeFile(named: "a.txt", contents: "a")])
        let landing = HeldLanding()
        defer { landing.release() }
        take.onLandingForTesting(landing.body)
        let destination = try makeDestination().appendingPathComponent("a.txt")
        let write = Task { await harness.write(take, item: 0, to: destination) }
        let staged = try await landing.began()
        // The rest of the drag's staging, beside the copy being landed.
        let rest = try harness.service.dragStagingForTesting.reserveScratchDirectory(
            generation: take.generation)

        harness.guestChannel.close()
        try await waitForChange { !harness.service.isConnected }

        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(FileManager.default.fileExists(atPath: rest.path))
        landing.release()
        #expect(await write.value == .landed)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "a")
        #expect(!FileManager.default.fileExists(atPath: rest.path))
    }

    @Test("each item lands at exactly the URL asked for — a file, and a folder as its tree")
    func itemsLandAtTheDestination() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let file = try makeFile(named: "report.txt", contents: "the report")
        let folder = try makeFolder(named: "Photos", files: ["a.txt": "alpha", "b.txt": "beta"])
        let take = try await harness.releasedTake([file, folder])
        #expect(take.items.map(\.type.identifier).last == "public.folder")
        let destination = try makeDestination()

        let fileTarget = destination.appendingPathComponent("report.txt")
        #expect(await harness.write(take, item: 0, to: fileTarget) == .landed)
        let folderTarget = destination.appendingPathComponent("Photos")
        #expect(await harness.write(take, item: 1, to: folderTarget) == .landed)

        #expect(try String(contentsOf: fileTarget, encoding: .utf8) == "the report")
        #expect(
            try String(contentsOf: folderTarget.appendingPathComponent("a.txt"), encoding: .utf8)
                == "alpha")
        #expect(
            try String(contentsOf: folderTarget.appendingPathComponent("b.txt"), encoding: .utf8)
                == "beta")
        // Every item written: nothing will pull from the drag again.
        try await harness.waitForComplete(take.generation)
        // One readout for the take, completed with its last write.
        try await harness.reports.changed.wait {
            harness.reports.reports.contains { report in
                guard case .finished(let finish) = report else { return false }
                return finish.gesture == .dragOut && finish.failure == nil
            }
        }
        #expect(harness.reports.refusals.isEmpty)
    }

    @Test("the readout completes as the last item lands, not after its idle gap")
    func readoutCompletesWithTheTake() async throws {
        // A gap no test outlasts: a finish seen at all came from the take's end.
        let harness = try Harness(progressIdleGap: 3600)
        defer { harness.tearDown() }
        let take = try await harness.releasedTake([
            try makeFile(named: "a.txt", contents: "a"), try makeFile(named: "b.txt", contents: "b"),
        ])
        let destination = try makeDestination()
        let finished = {
            harness.reports.reports.contains { report in
                guard case .finished(let finish) = report else { return false }
                return finish.gesture == .dragOut && finish.failure == nil
            }
        }

        #expect(await harness.write(take, item: 0, to: destination.appendingPathComponent("a.txt")) == .landed)
        // One item still owed: the readout waits for the destination's next ask.
        #expect(!finished())

        #expect(await harness.write(take, item: 1, to: destination.appendingPathComponent("b.txt")) == .landed)
        try await harness.reports.changed.wait { finished() }
        try await harness.waitForComplete(take.generation)
    }

    /// The live case: a home folder whose app data the guest agent may not
    /// read. The drag stops on the item, as Finder's copy does, and says which.
    @Test("a folder holding an item the guest cannot read fails the write, naming the item and why")
    func unreadableItemFailsTheWriteNamingIt() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let folder = try makeFolder(named: "Home", files: ["a.txt": "alpha", "z.txt": "zeta"])
        let library = folder.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let locked = library.appendingPathComponent("Mail.db")
        try Data("mail".utf8).write(to: locked)
        let sealed = try WithheldPermissions(locked)
        defer { withExtendedLifetime(sealed) {} }
        let take = try await harness.releasedTake([folder])
        let unreadable = ClipboardSourceReadFailure(
            itemPath: "Home/Library/Mail.db", reason: .posix(EACCES))

        let target = try makeDestination().appendingPathComponent("Home")
        #expect(
            await harness.write(take, item: 0, to: target) == .failed(.sourceUnreadable(unreadable)))

        #expect(!FileManager.default.fileExists(atPath: target.path))
        try await harness.reports.changed.wait { harness.reports.failure != nil }
        let finish = try #require(harness.reports.finish)
        #expect(finish.failure == .sourceUnreadable(unreadable))
        #expect(
            ClipboardTransferWording.wording(for: finish, vmName: "Guest")?.message
                == "The VM couldn't read \u{201C}Mail.db\u{201D} (permission denied), so the drag didn't finish.")
    }

    /// The live case: the same unreadable folder dragged again, its pull asked
    /// for as the drop lands and failing before a byte, inside the readout's
    /// reveal gate.
    @Test("a take's failure that repeats the last take's, before its readout reveals, is reported again")
    func repeatedFailureBeforeTheRevealIsReportedAgain() async throws {
        // A reveal no test outlasts: neither readout publishes a bar.
        let harness = try Harness(progressRevealDelay: 3600)
        defer { harness.tearDown() }
        let folder = try makeFolder(named: "Home", files: ["a.txt": "alpha"])
        let locked = folder.appendingPathComponent("Mail.db")
        try Data("mail".utf8).write(to: locked)
        let sealed = try WithheldPermissions(locked)
        defer { withExtendedLifetime(sealed) {} }
        let failure = ClipboardTransferFailure.sourceUnreadable(
            ClipboardSourceReadFailure(itemPath: "Home/Mail.db", reason: .posix(EACCES)))

        let first = try await harness.releasedTake([folder])
        let firstTarget = try makeDestination().appendingPathComponent("Home")
        #expect(await harness.write(first, item: 0, to: firstTarget) == .failed(failure))
        try await harness.reports.wait { harness.reports.refusals.count == 1 }

        let second = try await harness.carriedTake([folder])
        let secondTarget = try makeDestination().appendingPathComponent("Home")
        let write = Task { await harness.write(second, item: 0, to: secondTarget) }
        second.hostSessionEnded(dropped: true)
        harness.guest.sendDragHandOff(generation: second.generation, step: .caught)
        #expect(await write.value == .failed(failure))
        try await harness.waitForComplete(second.generation)

        // One notice per take: each refusal stood on its own, once.
        try await harness.reports.wait { harness.reports.refusals.count == 2 }
        #expect(harness.reports.refusals.allSatisfy { $0.gesture == .dragOut && $0.failure == failure })
    }

    @Test("a write held on its folder's size shows the readout, its total not yet known")
    func sizeWaitShowsTheReadout() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let folder = try makeFolder(named: "Docs", files: ["a.txt": "alpha"])
        let take = try await harness.carriedTake([folder], sendingSizes: false)
        take.hostSessionEnded(dropped: true)

        let target = try makeDestination().appendingPathComponent("Docs")
        let write = Task { await harness.write(take, item: 0, to: target) }
        try await harness.reports.wait { harness.reports.runningSnapshot?.awaitsSize == true }
        let waiting = try #require(harness.reports.runningSnapshot)
        #expect(waiting.gesture == .dragOut)
        #expect(waiting.bytesTransferred == 0)
        #expect(waiting.fractionComplete == 0)

        harness.sendSizes(of: take)
        #expect(await write.value == .landed)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.txt").path))
        // The size's arrival reached the readout as a total.
        #expect(
            harness.reports.reports.contains { report in
                guard case .running(let snapshot, _) = report else { return false }
                return !snapshot.awaitsSize && snapshot.totalBytes > 0
            })
    }

    @Test("the readout's Cancel fails the write in flight as cancelled and completes the drag")
    func cancelCallsOffTheWrites() async throws {
        let harness = try Harness(parksPulls: true)
        defer { harness.tearDown() }
        let take = try await harness.releasedTake([try makeFile(named: "a.txt", contents: "a")])
        let destination = try makeDestination().appendingPathComponent("a.txt")

        let write = Task { await harness.write(take, item: 0, to: destination) }
        // The guest has dialled the item's data connection, which the harness
        // holds back, so the pull is parked.
        _ = try await harness.parked.next()
        try await harness.reports.changed.wait { harness.reports.runningSnapshot != nil }
        #expect(harness.reports.runningSnapshot?.gesture == .dragOut)

        #expect(harness.reports.cancelShownTransfer())

        #expect(await write.value == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try await harness.waitForComplete(take.generation)
        // Asked again after the Cancel, the take refuses without pulling.
        #expect(await harness.write(take, item: 0, to: destination) == .cancelled)
    }

    @Test("the guest's own Cancel after the release ends the writes as cancelled, not failed")
    func guestCancelDuringAWriteCancels() async throws {
        let harness = try Harness(parksPulls: true)
        defer { harness.tearDown() }
        let take = try await harness.releasedTake([
            try makeFile(named: "a.txt", contents: "a"), try makeFile(named: "b.txt", contents: "b"),
        ])
        let destination = try makeDestination()

        let write = Task {
            await harness.write(take, item: 0, to: destination.appendingPathComponent("a.txt"))
        }
        _ = try await harness.parked.next()
        try await harness.reports.changed.wait { harness.reports.runningSnapshot != nil }
        // After the release, a withdrawal is the guest user's Cancel on its
        // serving readout.
        #expect(harness.guest.withdraw(generation: take.generation))

        #expect(await write.value == .cancelled)
        try await harness.reports.wait {
            harness.reports.reports.contains { report in
                guard case .finished(let finish) = report, case .cancelled = finish.outcome else {
                    return false
                }
                return finish.gesture == .dragOut
            }
        }
        #expect(harness.reports.refusals.isEmpty)
        #expect(
            await harness.write(take, item: 1, to: destination.appendingPathComponent("b.txt"))
                == .cancelled)
    }

    @Test("the channel ending while a destination is still owed items reports them interrupted when one is asked for")
    func channelEndWithItemsOwedIsReported() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.releasedTake([
            try makeFile(named: "a.txt", contents: "a"), try makeFile(named: "b.txt", contents: "b"),
            try makeFile(named: "c.txt", contents: "c"),
        ])
        let destination = try makeDestination()
        #expect(
            await harness.write(take, item: 0, to: destination.appendingPathComponent("a.txt"))
                == .landed)

        harness.guestChannel.close()
        try await waitForChange { !harness.service.isConnected }

        // A destination that never asks for the rest is told nothing.
        #expect(harness.reports.failure == nil)

        #expect(
            await harness.write(take, item: 1, to: destination.appendingPathComponent("b.txt"))
                == .failed(.interrupted(fileCount: 2)))
        try await harness.reports.waitForFailure()
        #expect(harness.reports.failure == .interrupted(fileCount: 2))
        #expect(harness.reports.finish?.gesture == .dragOut)
    }

    @Test("the channel ending once a session dropped nothing reports nothing")
    func channelEndWithNothingOwedIsQuiet() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let take = try await harness.releasedTake(
            [try makeFile(named: "a.txt", contents: "a")], dropped: false)
        try await harness.waitForComplete(take.generation)

        harness.guestChannel.close()
        try await waitForChange { !harness.service.isConnected }

        #expect(harness.reports.refusals.isEmpty)
    }
}
