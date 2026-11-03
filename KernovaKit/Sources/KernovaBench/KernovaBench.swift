#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// `kernova-bench`: measurements of Kernova's own code, built the same way on the host and inside guests.
@main
enum KernovaBench {
    static let usage = """
        usage: kernova-bench lz4 [--block-size <bytes>] [--threads <n>,<n>...] [--pairs <n>]
                                 [--encode-sample <bytes>] [--decode-sample <bytes>] <corpus>...
          <corpus> is <name>=<file>, the file read whole, or zeros=<bytes>.
          Defaults: --block-size 262144, --threads 1,2,4,<cores>, --pairs 25,
                    --encode-sample 8388608 and --decode-sample 33554432 bytes per thread.
        """

    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty, arguments.removeFirst() == "lz4" else { fail(usage) }
        let options: LZ4Bench.Options
        do {
            options = try LZ4Bench.Options(parsing: arguments)
        } catch {
            fail("\(error.message)\n\(usage)")
        }
        LZ4Bench(options: options).run()
    }

    static func fail(_ message: String) -> Never {
        print(message)
        exit(2)
    }
}

/// A command line `kernova-bench` refused, and why.
struct UsageError: Error {
    var message: String
}
