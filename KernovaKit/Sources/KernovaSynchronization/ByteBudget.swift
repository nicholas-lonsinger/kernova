/// A byte limit that several landings draw on together: each charges what it lands through an ``Account`` of
/// its own, and what an account charged returns to the budget unless the account keeps it.
///
/// Budgets compare by identity.
public final class ByteBudget: Sendable, Equatable {
    /// The most bytes every kept and open account may hold together.
    public let limit: UInt64
    private let spent = Locked<UInt64>(0)

    /// A budget of `limit` bytes, none spent.
    public init(limit: UInt64) {
        self.limit = limit
    }

    /// The bytes no account holds.
    public var remaining: UInt64 { limit - spent.withLock { $0 } }

    /// A fresh account, holding nothing.
    public func account() -> Account { Account(self) }

    /// Whether `lhs` and `rhs` are one budget.
    public static func == (lhs: ByteBudget, rhs: ByteBudget) -> Bool { lhs === rhs }

    private func take(_ bytes: UInt64) -> Bool {
        spent.withLock { spent in
            guard bytes <= limit - spent else { return false }
            spent += bytes
            return true
        }
    }

    private func give(_ bytes: UInt64) {
        spent.withLock { $0 -= bytes }
    }

    /// One landing's draw on a budget. What it charged returns to the budget when ``giveBack()`` runs or the
    /// account is released, unless ``keep()`` made it the budget's for good.
    public final class Account: Sendable {
        private struct State {
            var charged: UInt64 = 0
            var kept = false
        }

        /// The budget it draws on.
        public let budget: ByteBudget
        private let state = Locked(State())

        fileprivate init(_ budget: ByteBudget) {
            self.budget = budget
        }

        deinit { giveBack() }

        /// What it holds of the budget.
        public var charged: UInt64 { state.withLock(\.charged) }

        /// Charges `bytes` more, or nothing when the budget has fewer left.
        ///
        /// - Returns: whether it charged them.
        public func charge(_ bytes: UInt64) -> Bool {
            state.withLock { state in
                guard !state.kept, budget.take(bytes) else { return false }
                state.charged += bytes
                return true
            }
        }

        /// Makes what it charged the budget's for good: nothing it holds returns, and it charges no more.
        public func keep() {
            state.withLock { $0.kept = true }
        }

        /// Returns what it charged to the budget, unless it was kept.
        public func giveBack() {
            let returned = state.withLock { state -> UInt64 in
                guard !state.kept else { return 0 }
                defer { state.charged = 0 }
                return state.charged
            }
            if returned > 0 { budget.give(returned) }
        }
    }
}
