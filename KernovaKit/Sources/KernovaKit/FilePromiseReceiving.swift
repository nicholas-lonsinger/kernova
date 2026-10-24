import AppKit

/// The part of `NSFilePromiseReceiver` a drop that calls file promises in uses.
///
/// A protocol rather than the class itself so a test can play a promise source:
/// promises are written by the *dragging* side, and nothing on the receiving
/// side can put one on a pasteboard.
@MainActor
public protocol FilePromiseReceiving: AnyObject {
    /// The names of the files the promise's source says it writes.
    ///
    /// `NSFilePromiseReceiver` fills these in as its files are received, so a
    /// source can name nothing when the drag is taken — a Photos asset does.
    var fileNames: [String] { get }

    /// Asks the source to write its files into `destination`, calling `reader`
    /// on `operationQueue` once per file with the URL it landed at, or with
    /// the error that stopped it.
    func receivePromisedFiles(
        atDestination destination: URL, options: [AnyHashable: Any],
        operationQueue: OperationQueue, reader: @escaping (URL, (any Error)?) -> Void)
}

extension NSFilePromiseReceiver: FilePromiseReceiving {}
