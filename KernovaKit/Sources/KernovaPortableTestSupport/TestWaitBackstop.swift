#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Default stuck-condition backstop for every test wait helper, in seconds.
///
/// Sized past any plausible stall on a GitHub-hosted runner: 5 s and 10 s
/// backstops each timed out sound event-driven waits (2026-07-19, two
/// consecutive `main` runs, twelve waits). A success-path wait passes no
/// smaller explicit timeout; an explicit value is for a deadline the test
/// asserts.
///
/// A timeout injected into the subject is sized the same way — at least this
/// value, even where the production default is shorter — unless that
/// deadline is the behavior under test: a shorter one is a second clock racing the test body, and a
/// starved runner loses the race. The one exception runs the other way: a
/// timeout capping how long a test holds the main thread is
/// ``mainThreadHoldCap``.
public let testWaitBackstop: TimeInterval = 60

/// How long a test may hold the main thread, in seconds: a timeout injected to
/// cap a synchronous wait the test makes on the main thread, and every wait a
/// helper thread makes while the main thread waits on it.
///
/// Far below ``testWaitBackstop``, so a lost fast path fails that test alone
/// instead of freezing every concurrent test's main-actor work until their
/// backstops fire under their own names.
public let mainThreadHoldCap: TimeInterval = 5
