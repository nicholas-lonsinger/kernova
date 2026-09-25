import Foundation
import KernovaKit

/// One row of the library: a VM, or a create, clone or import whose bundle is
/// still being written.
///
/// Every VM verb takes a ``VMInstance``, so none can reach an arrival.
@MainActor
enum LibraryEntry {
    case vm(VMInstance)
    case arriving(VMArrival)

    var id: UUID {
        switch self {
        case .vm(let instance): instance.id
        case .arriving(let arrival): arrival.id
        }
    }

    var name: String {
        switch self {
        case .vm(let instance): instance.name
        case .arriving(let arrival): arrival.name
        }
    }

    /// The configuration the row is ordered and described by.
    var configuration: VMConfiguration {
        switch self {
        case .vm(let instance): instance.configuration
        case .arriving(let arrival): arrival.configuration
        }
    }

    var vm: VMInstance? {
        if case .vm(let instance) = self { instance } else { nil }
    }

    var arrival: VMArrival? {
        if case .arriving(let arrival) = self { arrival } else { nil }
    }

    /// The row's identity as an outline-view item.
    var object: AnyObject {
        switch self {
        case .vm(let instance): instance
        case .arriving(let arrival): arrival
        }
    }
}

/// A create, clone or import in flight: the bundle it is writing under the
/// hidden staging directory, until publication renames it to
/// ``destinationURL`` and ``VMLibrary/adopt(bundleAt:)`` turns it into a
/// ``VMInstance``.
@MainActor
@Observable
final class VMArrival {
    enum Kind: Sendable, Equatable {
        case creating
        case cloning(sourceID: UUID)
        case importing

        var displayLabel: String {
            switch self {
            case .creating: "Creating\u{2026}"
            case .cloning: "Cloning\u{2026}"
            case .importing: "Importing\u{2026}"
            }
        }

        /// The user-facing noun for this operation ("Creation" / "Clone" / "Import").
        var displayNoun: String {
            switch self {
            case .creating: "Creation"
            case .cloning: "Clone"
            case .importing: "Import"
            }
        }

        var cancelLabel: String { "Cancel \(displayNoun)" }

        var cancelAlertTitle: String { "Cancel \(displayNoun)?" }

        /// The verb whose failure this arrival's failure is.
        var verb: VMVerb {
            switch self {
            case .creating: .create
            case .cloning: .clone
            case .importing: .importVM
            }
        }
    }

    enum Stage: Equatable {
        /// The bundle is being written under the staging directory.
        case writing
        /// A cancel was taken; the write is settling, and nothing publishes.
        case cancelling
        /// The write finished and the rename into the VMs directory is under
        /// way — past the point a cancel can stop.
        case publishing
    }

    /// The identifier of the VM this arrival becomes.
    let id: UUID
    let kind: Kind
    /// What the write was asked for — the name, listing and description the
    /// row shows until the VM is read from its published bundle.
    let configuration: VMConfiguration
    /// Where publication renames the finished bundle.
    let destinationURL: URL

    private(set) var stage: Stage = .writing

    /// Where the write's tree sits until publication, once one was minted.
    @ObservationIgnored var stagedURL: URL?

    var name: String { configuration.name }

    /// What a surface shows for this row.
    var displayLabel: String { stage == .cancelling ? "Cancelling\u{2026}" : kind.displayLabel }

    @ObservationIgnored private let run: @MainActor (VMArrival) async throws -> VMInstance

    /// The arrival's outcome: the VM its published bundle became, or why none
    /// did. Started when the arrival is made, on the main actor's next turn.
    @ObservationIgnored private(set) lazy var settled: Task<VMInstance, any Error> = Task {
        try await run(self)
    }

    /// Makes an arrival whose write `run` performs, starting it.
    ///
    /// `run` begins on a later main-actor turn, so whatever registers the
    /// arrival in the same synchronous segment does so before it.
    init(
        id: UUID, kind: Kind, configuration: VMConfiguration, destinationURL: URL,
        run: @escaping @MainActor (VMArrival) async throws -> VMInstance
    ) {
        self.id = id
        self.kind = kind
        self.configuration = configuration
        self.destinationURL = destinationURL
        self.run = run
        _ = settled
    }

    /// What a cancel found.
    enum CancelDecision: Equatable {
        /// The write was stopped short of publication.
        case cancelled
        /// An earlier cancel already stopped it.
        case alreadyCancelling
        /// The rename is under way; the arrival is about to be a VM.
        case publishing
    }

    /// Stops the write short of publication, unless the rename has begun.
    func requestCancel() -> CancelDecision {
        switch stage {
        case .writing:
            stage = .cancelling
            settled.cancel()
            return .cancelled
        case .cancelling:
            return .alreadyCancelling
        case .publishing:
            return .publishing
        }
    }

    /// Moves the arrival past the last point a cancel can stop it, answering
    /// `false` when one already has.
    func beginPublishing() -> Bool {
        guard stage == .writing else { return false }
        stage = .publishing
        return true
    }
}
