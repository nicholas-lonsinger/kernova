#if os(Linux)
// Apple's Dispatch marks its source protocols `Sendable`; swift-corelibs-libdispatch does not.
@preconcurrency import Dispatch
import KernovaAgentCore
import KernovaDBus
import KernovaSynchronization

/// A peer's place in the guest's sessions, read from logind.
///
/// Every Linux peer runs as a systemd service — the session peer in `user@UID.service`, the system peer as
/// a system unit — so neither belongs to a logind session, and `GetSessionByPID` fails for both
/// (docs/research/2026-10-28-linux-logind-polkit-user-service-and-inhibitors.md, finding 4). The session
/// peer reads its user's `Display` session instead, and the system peer seat0's `ActiveSession`.
public enum LogindPeerState {
    /// The session peer's state: its user's display session's `Id`, the console ON while that session is
    /// active, of class `user` and on a seat, and the user's login name. Nil when logind can elect no
    /// display session for the user, as for a lingering user with no session at all.
    public static func sessionPeer(_ logind: Logind, uid: UInt32) throws(LogindError) -> PeerSessionState? {
        let user = try logind.user(uid)
        guard let display = try logind.displaySession(ofUser: user) else { return nil }
        let properties = try logind.sessionProperties(display.path)
        return PeerSessionState(
            console: properties.ownsConsole ? .on : .off, sessionID: properties.id,
            userName: try logind.userName(user))
    }

    /// The system peer's state: the console ON, naming the session, while seat0's foreground session is
    /// a user's; OFF at the greeter, and OFF when seat0 has no foreground session, as on a headless guest.
    /// logind always has seat0; an answer that it has none reads OFF too. It is never UNKNOWN, which
    /// would make the host pass over every session peer.
    public static func systemPeer(_ logind: Logind) throws(LogindError) -> PeerSessionState {
        let seat: DBusObjectPath
        do throws(LogindError) {
            seat = try logind.seat("seat0")
        } catch .call(.remote(let error)) where error.name == noSuchSeat {
            return PeerSessionState(console: .off)
        }
        guard let active = try logind.activeSession(onSeat: seat) else { return PeerSessionState(console: .off) }
        let properties = try logind.sessionProperties(active.path)
        guard properties.ownsConsole else { return PeerSessionState(console: .off) }
        return PeerSessionState(console: .on, consoleSessionID: properties.id)
    }

    /// Delivers the session peer's state on `queue` once its user has a display session: at once when
    /// they have one, or else after the next session logind starts gives them one. The read runs on
    /// `queue`, never on the connection's reader thread. `deliver` runs exactly once; a failed read ends
    /// the wait with its error.
    public static func awaitSessionPeer(
        _ logind: Logind, uid: UInt32, on queue: DispatchQueue,
        _ deliver: @escaping @Sendable (Result<PeerSessionState, LogindError>) -> Void
    ) {
        let wait = SessionWait(deliver)
        queue.async {
            // Subscribed before the first read, so a session that starts between the two is not missed.
            let subscription: DBusSubscription
            do throws(LogindError) {
                subscription = try logind.observeNewSessions { _ in
                    queue.async { wait.check(logind, uid: uid) }
                }
            } catch {
                return wait.finish(.failure(error))
            }
            wait.hold(subscription)
            wait.check(logind, uid: uid)
        }
    }

    private static let noSuchSeat = "org.freedesktop.login1.NoSuchSeat"
}

/// One `awaitSessionPeer` wait: its subscription, held until the state is delivered.
private final class SessionWait: Sendable {
    private struct State: Sendable {
        var deliver: (@Sendable (Result<PeerSessionState, LogindError>) -> Void)?
        var subscription: DBusSubscription?
    }

    private let state: Locked<State>

    init(_ deliver: @escaping @Sendable (Result<PeerSessionState, LogindError>) -> Void) {
        state = Locked(State(deliver: deliver))
    }

    func hold(_ subscription: DBusSubscription) {
        let finished = state.withLock { state in
            guard state.deliver != nil else { return true }
            state.subscription = subscription
            return false
        }
        if finished { subscription.cancel() }
    }

    func check(_ logind: Logind, uid: UInt32) {
        guard state.withLock({ $0.deliver != nil }) else { return }
        do throws(LogindError) {
            guard let peerState = try LogindPeerState.sessionPeer(logind, uid: uid) else { return }
            finish(.success(peerState))
        } catch {
            finish(.failure(error))
        }
    }

    func finish(_ result: Result<PeerSessionState, LogindError>) {
        let (deliver, subscription) = state.withLock { state in
            defer { state = State() }
            return (state.deliver, state.subscription)
        }
        subscription?.cancel()
        deliver?(result)
    }
}

extension LogindSessionProperties {
    /// Whether the session holds the guest's screen: on a seat, in the foreground there, and a user's
    /// rather than a greeter's or a lock screen's. A seatless session, which logind reports as always
    /// active, holds no screen.
    var ownsConsole: Bool {
        seat != nil && active && sessionClass == .user
    }
}
#endif
