import AppKit

/// The part of `NSFilePromiseReceiver` a display drop uses.
///
/// A protocol rather than the class itself so a test can play a promise source:
/// promises are written by the *dragging* side, and nothing on the receiving
/// side can put one on a pasteboard.
@MainActor
protocol DisplayDropPromiseReceiving {
    /// The names of the files this receiver will write.
    var fileNames: [String] { get }

    /// Asks the source to write its files into `destination`, calling `reader`
    /// once per file with the URL it landed at, or with the error that stopped
    /// it.
    func receivePromisedFiles(
        atDestination destination: URL, options: [AnyHashable: Any],
        operationQueue: OperationQueue, reader: @escaping (URL, (any Error)?) -> Void)
}

extension NSFilePromiseReceiver: DisplayDropPromiseReceiving {}

/// How a display finds the file promises a drag carries.
///
/// Two closures rather than one: the check runs on every pointer move while a
/// drag is over the display, so it stays a `canReadObject`, while reading the
/// receivers happens once, at the release.
struct DisplayDropPromiseSource {
    /// Whether this pasteboard advertises any file promise.
    var carriesPromises: @MainActor (NSPasteboard) -> Bool

    /// The receivers for the promises it carries, in drag order.
    var receivers: @MainActor (NSPasteboard) -> [any DisplayDropPromiseReceiving]

    /// What a real drag carries.
    static let pasteboard = DisplayDropPromiseSource(
        carriesPromises: { pasteboard in
            pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        },
        receivers: { pasteboard in
            pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
                as? [NSFilePromiseReceiver] ?? []
        })
}
