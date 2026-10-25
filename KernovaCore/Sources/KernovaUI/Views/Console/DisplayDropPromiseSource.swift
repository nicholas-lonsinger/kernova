import AppKit
import KernovaKit

/// How a display finds the file promises a drag carries.
///
/// Two closures rather than one: the check runs on every pointer move while a
/// drag is over the display, so it stays a `canReadObject`, while reading the
/// receivers happens once, at the release.
struct DisplayDropPromiseSource {
    /// Whether this pasteboard advertises any file promise.
    var carriesPromises: @MainActor (NSPasteboard) -> Bool

    /// The receivers for the promises it carries, in drag order.
    var receivers: @MainActor (NSPasteboard) -> [any FilePromiseReceiving]

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
