#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Bytes a bench mode measures over: a file read whole, or zeros made by the bench.
enum CorpusSource {
    case file(String)
    case zeros(Int)

    /// The corpus a command-line argument names: `<name>=<file>`, or `zeros=<bytes>`.
    ///
    /// - Parameter argument: The argument.
    /// - Returns: The corpus's name and source.
    /// - Throws: `UsageError` when it names no corpus.
    static func parse(_ argument: String) throws(UsageError) -> (name: String, source: CorpusSource) {
        guard let equals = argument.firstIndex(of: "="), equals != argument.startIndex else {
            throw UsageError(message: "not an option or a corpus: \(argument)")
        }
        let name = String(argument[..<equals])
        let value = String(argument[argument.index(after: equals)...])
        guard name == "zeros" else { return (name, .file(value)) }
        guard let count = Int(value), count > 0 else {
            throw UsageError(message: "zeros takes a positive byte count, not \(value)")
        }
        return (name, .zeros(count))
    }

    /// The corpus's bytes; a file that cannot be read ends the bench.
    func load() -> Data {
        switch self {
        case .zeros(let count):
            return Data(count: count)
        case .file(let path):
            do {
                return try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                KernovaBench.fail("cannot read \(path): \(error)")
            }
        }
    }
}

/// 1, 2 and 4, and the active core count, each at most the active cores and once.
func defaultThreadCounts() -> [Int] {
    let cores = ProcessInfo.processInfo.activeProcessorCount
    var counts: [Int] = []
    for count in [1, 2, 4, cores] where count <= cores && !counts.contains(count) { counts.append(count) }
    return counts
}

/// The 1, 5 and 15-minute load averages, where the platform has them.
func loadAverage() -> String {
    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    var loads = [Double](repeating: 0, count: 3)
    guard getloadavg(&loads, 3) == 3 else { return "unavailable" }
    return loads.map { fixed($0, 2) }.joined(separator: " ")
    #else
    return "unavailable"
    #endif
}
