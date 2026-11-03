#if os(macOS)
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import KernovaAgentCore
import KernovaSynchronization
import SystemConfiguration

/// A macOS peer's place in the guest's sessions.
public enum DarwinSessionState {
    /// The session peer's state: its audit session's id, whether its window-server session owns the console
    /// (`CGSessionCopyCurrentDictionary`, `kCGSessionOnConsoleKey`), and its user's login name. The console is
    /// unknown when the process has no window-server session.
    public static func sessionPeer() -> PeerSessionState {
        var console = ConsoleState.unknown
        var userName = ""
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool { console = onConsole ? .on : .off }
            if let name = session[kCGSessionUserNameKey as String] as? String { userName = name }
        }
        if userName.isEmpty, let entry = getpwuid(getuid()) { userName = String(cString: entry.pointee.pw_name) }
        return PeerSessionState(console: console, sessionID: auditSessionID.map(String.init) ?? "", userName: userName)
    }

    /// The process's audit session id, the macOS session identifier (`getaudit_addr(2)`).
    public static var auditSessionID: Int32? {
        var info = auditinfo_addr()
        guard getaudit_addr(&info, Int32(MemoryLayout<auditinfo_addr>.size)) == 0 else { return nil }
        return info.ai_asid
    }

    /// The system peer's state when `consoleUser` is the console's user, as `SCDynamicStoreCopyConsoleUser`
    /// names it: off at the login window or with no user at all, unknown while a user has it.
    ///
    /// Unknown rather than on: the console's audit session id, which the session peers report as theirs, is not
    /// among what `SCDynamicStoreCopyConsoleUser` returns (a user name, uid and gid), so with a user at the console
    /// the system peer leaves the console to the session peers' own reports.
    public static func systemPeer(consoleUser: String?) -> PeerSessionState {
        guard let consoleUser, !consoleUser.isEmpty, consoleUser != loginWindowUser else {
            return PeerSessionState(console: .off)
        }
        return PeerSessionState(console: .unknown)
    }

    /// The name `SCDynamicStoreCopyConsoleUser` gives the console at the login window.
    static let loginWindowUser = "loginwindow"

    /// The console's user and uid now; nil with none.
    public static func consoleUser() -> (name: String, uid: uid_t)? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String? else { return nil }
        return (name, uid)
    }

    /// The uid of the user at the console now; nil at the login window or with no user.
    public static func consoleUserID() -> uid_t? {
        guard let user = consoleUser(), user.name != loginWindowUser, user.uid != 0 else { return nil }
        return user.uid
    }
}

/// Follows the console's user in the dynamic store, handing the system peer's state to `onChange` on `queue`:
/// once at start, then on every change of the console user key (`SCDynamicStoreKeyCreateConsoleUser`).
public final class ConsoleUserWatcher: Sendable {
    /// Set once; the dynamic store's calls are safe from any thread.
    private nonisolated(unsafe) let store: SCDynamicStore
    private let cancelled = Locked(false)
    private let box: Box

    private final class Box: Sendable {
        let onChange: @Sendable (PeerSessionState) -> Void
        init(_ onChange: @escaping @Sendable (PeerSessionState) -> Void) { self.onChange = onChange }
        func fire() { onChange(DarwinSessionState.systemPeer(consoleUser: DarwinSessionState.consoleUser()?.name)) }
    }

    /// A watcher calling `onChange` on `queue`; nil when the dynamic store cannot be watched.
    public init?(queue: DispatchQueue, _ onChange: @escaping @Sendable (PeerSessionState) -> Void) {
        let box = Box(onChange)
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().fire()
        }
        guard let store = SCDynamicStoreCreate(nil, "app.kernova.macosagent" as CFString, callback, &context) else {
            return nil
        }
        let key = SCDynamicStoreKeyCreateConsoleUser(nil)
        guard SCDynamicStoreSetNotificationKeys(store, [key] as CFArray, nil),
            SCDynamicStoreSetDispatchQueue(store, queue)
        else { return nil }
        self.box = box
        self.store = store
        queue.async { box.fire() }
    }

    /// Stops watching.
    public func cancel() {
        guard
            !cancelled.withLock({ cancelled in
                defer { cancelled = true }; return cancelled
            })
        else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
    }

    deinit {
        cancel()
    }
}

/// Watches an install root for its `current` link to point away from the slot this process runs from, as an
/// update's switch or the rollback check's revert moves it, and calls `onMoved` once, on `queue`.
public final class SlotLinkWatcher: Sendable {
    private let source: any DispatchSourceFileSystemObject

    /// A watcher of `root`, whose process runs from `runningSlot`; nil when the root cannot be opened.
    public init?(root: String, runningSlot: String, queue: DispatchQueue, onMoved: @escaping @Sendable () -> Void) {
        let directory = open(root, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directory, eventMask: [.write, .delete, .rename], queue: queue)
        let fired = Locked(false)
        let check: @Sendable () -> Void = {
            guard Self.slot(linkedFrom: root + "/current") != runningSlot else { return }
            guard
                !fired.withLock({ fired in
                    defer { fired = true }; return fired
                })
            else { return }
            source.cancel()
            onMoved()
        }
        source.setEventHandler(handler: check)
        source.setCancelHandler { close(directory) }
        self.source = source
        source.resume()
        // A move before the source armed is not lost.
        queue.async(execute: check)
    }

    /// Stops watching.
    public func cancel() {
        source.cancel()
    }

    /// The slot the link at `path` points at, `slots/<slot>`; nil when it is missing or points elsewhere.
    static func slot(linkedFrom path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        let target = String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard target.hasPrefix("slots/") else { return nil }
        return String(target.dropFirst("slots/".count))
    }
}
#endif
