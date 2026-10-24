import KernovaKit
import Testing

@Suite("FilePromiseTally")
struct FilePromiseTallyTests {
    @Test("a receiver that names nothing still owes one callback")
    func anUnnamedReceiverOwesOne() {
        var tally = FilePromiseTally(receivers: [0])
        #expect(!tally.isQuiesced)
        #expect(tally.record(from: 0, naming: 0) == 1)
        #expect(tally.isQuiesced)
    }

    @Test("every receiver must report every file it names")
    func everyReceiverReportsEveryName() {
        var tally = FilePromiseTally(receivers: [0, 1])
        tally.record(from: 0, naming: 2)
        tally.record(from: 1, naming: 1)
        #expect(!tally.isQuiesced)
        #expect(tally.record(from: 0, naming: 2) == 2)
        #expect(tally.isQuiesced)
    }

    @Test("a name count that reads short later cannot shrink what is owed")
    func owedIsTheMostEverNamed() {
        var tally = FilePromiseTally(receivers: ["a"])
        tally.record(from: "a", naming: 3)
        tally.record(from: "a", naming: 0)
        #expect(!tally.isQuiesced)
        tally.record(from: "a", naming: 1)
        #expect(tally.isQuiesced)
    }

    @Test("names that appear as files land raise what is owed")
    func namesAppearingRaiseOwed() {
        var tally = FilePromiseTally(receivers: [0, 1])
        tally.record(from: 1, naming: 1)
        tally.record(from: 0, naming: 2)
        #expect(!tally.isQuiesced)
        tally.record(from: 0, naming: 2)
        #expect(tally.isQuiesced)
    }

    @Test("once quiesced, a receiver naming more than it reported cannot un-latch it")
    func quiescenceLatches() {
        var tally = FilePromiseTally(receivers: [0])
        tally.record(from: 0, naming: 1)
        #expect(tally.isQuiesced)
        #expect(tally.record(from: 0, naming: 5) == 2)
        #expect(tally.isQuiesced)
    }

    @Test("a tally of no receivers is quiesced from the start")
    func noReceiversIsQuiesced() {
        #expect(FilePromiseTally<Int>(receivers: []).isQuiesced)
    }
}
