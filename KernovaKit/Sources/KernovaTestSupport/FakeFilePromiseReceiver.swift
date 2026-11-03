import Foundation
import KernovaKit

/// A file promise whose source a test plays: it names its files, each of one
/// type, up front or once called in, and writes them into the destination it
/// is called in to — at once, or each when the test delivers it.
@MainActor
public final class FakeFilePromiseReceiver: FilePromiseReceiving {
    /// What the source writes when called in.
    public enum Contents: Sendable {
        /// A regular file of these bytes.
        case file(Data)
        /// A folder holding these files, by name.
        case folder([String: Data])
        /// Nothing: the source reports this failure.
        case failure
    }

    private struct Failure: Error {}

    private let files: [(name: String, contents: Contents)]
    private let deferred: Bool
    private var calledIn: (destination: URL, reader: (URL, (any Error)?) -> Void)?

    /// Its files' names: up front, or once called in.
    public private(set) var fileNames: [String]
    /// Its files' type, declared up front.
    public let fileTypes: [String]

    /// How many times it has been called in.
    public private(set) var callIns = 0

    /// A promise of one file `name`, of type `fileType`, writing `contents`.
    /// `named` false leaves `fileNames` empty until it is called in, as a
    /// Photos asset does.
    public convenience init(name: String, fileType: String, contents: Contents, named: Bool = true) {
        self.init(files: [(name, contents)], fileType: fileType, named: named)
    }

    /// A promise of `files`, each of type `fileType`. `named` false leaves
    /// `fileNames` empty until it is called in; `deferred` writes nothing when
    /// called in, each file then written and reported by ``deliver(_:)``.
    public init(
        files: [(name: String, contents: Contents)], fileType: String, named: Bool = true, deferred: Bool = false
    ) {
        self.files = files
        self.deferred = deferred
        self.fileTypes = [fileType]
        self.fileNames = named ? files.map(\.name) : []
    }

    /// Writes its files into `destination` and reports each to `reader`
    /// before returning, rather than on `operationQueue` — or, `deferred`,
    /// keeps both for ``deliver(_:)``.
    public func receivePromisedFiles(
        atDestination destination: URL, options: [AnyHashable: Any], operationQueue: OperationQueue,
        reader: @escaping (URL, (any Error)?) -> Void
    ) {
        callIns += 1
        fileNames = files.map(\.name)
        calledIn = (destination, reader)
        guard !deferred else { return }
        for index in files.indices { deliver(index) }
    }

    /// Writes file `index` where it was called in to, and reports it.
    public func deliver(_ index: Int) {
        guard let (destination, reader) = calledIn else { preconditionFailure("delivered before a call-in") }
        let (name, contents) = files[index]
        let url = destination.appendingPathComponent(name)
        do {
            switch contents {
            case .file(let data):
                try data.write(to: url)
            case .folder(let files):
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                for (file, data) in files { try data.write(to: url.appendingPathComponent(file)) }
            case .failure:
                throw Failure()
            }
            reader(url, nil)
        } catch {
            reader(url, error)
        }
    }
}
