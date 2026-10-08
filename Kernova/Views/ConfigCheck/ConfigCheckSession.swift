import Foundation
import KernovaLogging

/// What the config check reads and repairs the library's config files
/// through.
@MainActor
protocol ConfigCheckSource: AnyObject {
    func checkConfigFiles() async throws -> [UnreadableConfigFile]
    func useDefaults(in files: [UnreadableConfigFile]) async -> [VMLibrary.ConfigFileRepairFailure]
    /// The folder the report writes paths relative to, `nil` when it cannot
    /// be resolved.
    var libraryDirectory: URL? { get }
}

extension VMLibraryViewModel: ConfigCheckSource {}

/// The Check Config Files window's work — each check, and Use Defaults — and
/// what the last check found.
///
/// The work is one state, so a check or a repair that ends after another has
/// begun changes nothing it did not begin.
@MainActor
@Observable
final class ConfigCheckSession {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "ConfigCheckSession")

    enum Work: Equatable {
        case idle
        /// The check `token` names is under way, and only its result lands.
        case checking(token: Int)
        /// Use Defaults is under way, and it ends in a check of its own.
        case repairing
    }

    private(set) var work: Work = .idle
    /// What the last check found, `nil` while none has finished or the last
    /// one failed.
    private(set) var report: ConfigCheckReport?
    /// Why the last check could not list the files, `nil` when it could.
    private(set) var failure: String?

    @ObservationIgnored private let source: any ConfigCheckSource
    @ObservationIgnored private var lastToken = 0

    /// Told the files a Use Defaults left as they were, as the report it
    /// started from names them.
    @ObservationIgnored var onRepairFailures: ((_ lines: [String]) -> Void)?

    init(source: any ConfigCheckSource) {
        self.source = source
    }

    /// Reads every config file again; a check already under way is
    /// superseded, and one asked for during Use Defaults is the check it ends
    /// in.
    func check() {
        if work == .repairing { return }
        lastToken += 1
        let token = lastToken
        work = .checking(token: token)
        failure = nil
        Task { [weak self, source] in
            let outcome: Result<[UnreadableConfigFile], any Error>
            do {
                outcome = .success(try await source.checkConfigFiles())
            } catch {
                outcome = .failure(error)
            }
            guard let self, self.work == .checking(token: token) else { return }
            switch outcome {
            case .success(let files):
                self.report = ConfigCheckReport(files: files, libraryDirectory: source.libraryDirectory)
                self.failure = nil
            case .failure(let error):
                #log(
                    Self.logger, .error,
                    "The config check couldn't list the VMs folder: \(error.localizedDescription, privacy: .public)"
                )
                self.report = nil
                self.failure = error.localizedDescription
            }
            self.work = .idle
        }
    }

    /// Puts the defaults in place in every repairable file the report lists,
    /// then checks again — only while no other work is under way.
    func useDefaults() {
        guard work == .idle, let report, report.repairableCount > 0 else { return }
        work = .repairing
        Task { [weak self, source] in
            let failures = await source.useDefaults(in: report.files)
            guard let self else { return }
            self.work = .idle
            self.check()
            guard !failures.isEmpty else { return }
            self.onRepairFailures?(failures.map { "\(report.relativePath(of: $0.file.url)): \($0.reason)" })
        }
    }
}
