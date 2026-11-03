import Foundation
import KernovaKit

/// A file promise whose source a test plays: it names one file of one type
/// up front, and writes it into the destination it is called in to.
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

    private let name: String
    private let contents: Contents

    /// Its one file's name: up front, or once called in.
    public private(set) var fileNames: [String]
    /// Its one file's type, declared up front.
    public let fileTypes: [String]

    /// How many times it has been called in.
    public private(set) var callIns = 0

    /// A promise of `name`, of type `fileType`, writing `contents`. `named`
    /// false leaves `fileNames` empty until it is called in, as a Photos
    /// asset does.
    public init(name: String, fileType: String, contents: Contents, named: Bool = true) {
        self.name = name
        self.contents = contents
        self.fileTypes = [fileType]
        self.fileNames = named ? [name] : []
    }

    /// Writes its file into `destination` and reports it to `reader` before
    /// returning, rather than on `operationQueue`.
    public func receivePromisedFiles(
        atDestination destination: URL, options: [AnyHashable: Any], operationQueue: OperationQueue,
        reader: @escaping (URL, (any Error)?) -> Void
    ) {
        callIns += 1
        fileNames = [name]
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
