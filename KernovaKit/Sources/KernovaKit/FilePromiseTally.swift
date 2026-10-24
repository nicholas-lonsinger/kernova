/// Counts the reader callbacks one drop's file promises deliver, and says when
/// nothing more will be written into the folder they were called into.
///
/// Each receiver owes at least one callback and as many as it has named. How
/// many it names is asked of it again at every callback rather than totalled
/// when the drop is taken: `NSFilePromiseReceiver` fills `fileNames` in as its
/// files are received, so a source that names nothing up front — a Photos asset
/// does — still owes the one file its presence on the pasteboard promises.
public struct FilePromiseTally<Key: Hashable> {
    /// How many callbacks each receiver owes: the most files it has ever named,
    /// so a count that reads short mid-write cannot shrink what is still owed —
    /// and never fewer than one: a receiver that names nothing is on the
    /// pasteboard because it promises something, and its names appear only as
    /// that something lands.
    private var owed: [Key: Int]
    /// How many callbacks each receiver has delivered.
    private var reported: [Key: Int]

    /// Whether every receiver has delivered every callback it owes, so nothing
    /// more will be written into the promises' folder.
    ///
    /// A latch, so a source that reports more often than its names account for
    /// cannot un-latch it and strand the folder.
    public private(set) var isQuiesced: Bool

    /// A tally of the receivers `keys` name, none of which has reported yet;
    /// one of no receivers is quiesced from the start.
    public init(receivers keys: some Sequence<Key>) {
        owed = Dictionary(keys.map { ($0, 1) }, uniquingKeysWith: { first, _ in first })
        reported = owed.mapValues { _ in 0 }
        isQuiesced = owed.isEmpty
    }

    /// Records one callback from the receiver `key` names, which names `names`
    /// files as of it — a receiver already gone passes 0 and owes whatever it
    /// last named — returning how many callbacks that receiver has now
    /// delivered.
    @discardableResult
    public mutating func record(from key: Key, naming names: Int) -> Int {
        precondition(owed[key] != nil, "A callback from a receiver the tally does not hold")
        let count = reported[key, default: 0] + 1
        reported[key] = count
        owed[key] = max(owed[key, default: 1], names)
        isQuiesced = isQuiesced || owed.allSatisfy { key, owes in reported[key, default: 0] >= owes }
        return count
    }
}

extension FilePromiseTally: Sendable where Key: Sendable {}
