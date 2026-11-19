import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The grants of one path, held by every kind of holder in every order, against a sandbox counting them as a Mac
/// does.
@Suite("SandboxFileGrants", .caseScoped)
struct SandboxFileGrantsTests {
    /// One holder of a path.
    enum Holder: CaseIterable {
        /// A security-scoped access whose start took a grant.
        case started
        /// A pasteboard read that took a grant.
        case pasteboardTook
        /// A pasteboard read that took none, as one past an exhausted grant budget does.
        case pasteboardTookNone
    }

    /// One step: holder `holder` takes the path, or lets go of it.
    struct Step: CustomStringConvertible {
        let holder: Int
        let takes: Bool
        var description: String { "\(takes ? "take" : "let go") \(holder)" }
    }

    /// Every order in which `count` holders each take the path and later let go of it.
    static func orders(of count: Int) -> [[Step]] {
        func extend(_ order: [Step], taken: Set<Int>, letGo: Set<Int>) -> [[Step]] {
            guard letGo.count < count else { return [order] }
            var orders: [[Step]] = []
            for holder in 0..<count where !letGo.contains(holder) {
                if taken.contains(holder) {
                    orders += extend(
                        order + [Step(holder: holder, takes: false)], taken: taken, letGo: letGo.union([holder]))
                } else {
                    orders += extend(
                        order + [Step(holder: holder, takes: true)], taken: taken.union([holder]), letGo: letGo)
                }
            }
            return orders
        }
        return extend([], taken: [], letGo: [])
    }

    /// Every kind of three holders, in every order: a holder that took a grant keeps the path granted until it lets
    /// go, and a grant no read took is given back only once nothing holds the path.
    @Test("Each holder of a path keeps its grant until it lets go, whoever else holds the path, in any order")
    func everyOrderKeepsEachHolderGranted() {
        let path = URL(fileURLWithPath: "/Volumes/Data/disk.img")
        let orders = Self.orders(of: 3)
        #expect(orders.count == 90)
        for first in Holder.allCases {
            for second in Holder.allCases {
                for third in Holder.allCases {
                    let kinds = [first, second, third]
                    for order in orders {
                        let sandbox = FakeSandbox()
                        let grants = sandbox.fileGrants
                        var held: [Int: SandboxFileGrants.Grant] = [:]
                        var live: Set<Int> = []
                        for step in order {
                            let unheldBefore = sandbox.unheldGiveBacks.count
                            switch (kinds[step.holder], step.takes) {
                            case (.started, true):
                                held[step.holder] = grants.startAccessing(path)
                                #expect(held[step.holder] != nil)
                            case (.pasteboardTook, true):
                                sandbox.grant(path)
                                held[step.holder] = grants.pasteboardGranted(path)
                            case (.pasteboardTookNone, true):
                                held[step.holder] = grants.pasteboardGranted(path)
                            case (_, false):
                                held.removeValue(forKey: step.holder)?.release()
                            }
                            if step.takes { live.insert(step.holder) } else { live.remove(step.holder) }
                            let granted = live.contains { kinds[$0] != .pasteboardTookNone }
                            #expect(
                                !granted || sandbox.grants(of: path) > 0,
                                "\(kinds) \(order): a holder lost its grant at \(step)")
                            #expect(
                                live.isEmpty || sandbox.unheldGiveBacks.count == unheldBefore,
                                "\(kinds) \(order): a grant was given back while the path was held, at \(step)")
                        }
                        #expect(sandbox.grants(of: path) == 0, "\(kinds) \(order)")
                        #expect(
                            sandbox.unheldGiveBacks.count == kinds.filter { $0 == .pasteboardTookNone }.count,
                            "\(kinds) \(order)")
                    }
                }
            }
        }
    }

    @Test("A grant released again, or let go after its release, is given back once")
    func grantIsGivenBackOnce() {
        let path = URL(fileURLWithPath: "/Volumes/Data/disk.img")
        let sandbox = FakeSandbox()
        let started = sandbox.fileGrants.startAccessing(path)
        sandbox.grant(path)
        let read = sandbox.fileGrants.pasteboardGranted(path)

        started?.release()
        started?.release()
        #expect(sandbox.grants(of: path) == 1, "the read's grant, still held")
        read.release()
        read.release()

        #expect(sandbox.grants(of: path) == 0)
        #expect(sandbox.unheldGiveBacks.isEmpty)
    }
}
