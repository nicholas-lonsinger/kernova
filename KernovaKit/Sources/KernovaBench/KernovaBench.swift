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
               kernova-bench pipeline [--workers <n>,<n>...] [--entry-size <bytes>] [--feed-size <bytes>]
                                      [--runs <n>] [--abandon-after <n>|never] <corpus>...
               kernova-bench tree [--compression policy|lz4|none] [--decode-workers <n>] <source> <destination>
          <corpus> is <name>=<file>, the file read whole, or zeros=<bytes>.
          lz4 defaults: --block-size 262144, --threads 1,2,4,<cores>, --pairs 25,
                        --encode-sample 8388608 and --decode-sample 33554432 bytes per thread.
          pipeline defaults: --workers 1,2,4,<cores>, --entry-size 4194304, --feed-size 1048576, --runs 5,
                             --abandon-after the transfer policy's.
          tree moves <source> into the directory <destination> through a transfer's reader, codec and writer,
               then compares the landing with the source; defaults: --compression policy (guest to host on
               this machine's cores), --decode-workers the transfer policy's.
        """

    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else { fail(usage) }
        let mode = arguments.removeFirst()
        do {
            switch mode {
            case "lz4": LZ4Bench(options: try LZ4Bench.Options(parsing: arguments)).run()
            case "pipeline": PipelineBench(options: try PipelineBench.Options(parsing: arguments)).run()
            #if canImport(Darwin) || os(Linux)
            case "tree": TreeBench(options: try TreeBench.Options(parsing: arguments)).run()
            #endif
            default: fail(usage)
            }
        } catch {
            fail("\(error.message)\n\(usage)")
        }
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
