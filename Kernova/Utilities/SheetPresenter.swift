import AppKit
import UniformTypeIdentifiers

/// Async wrappers around `NSWindow.beginSheet(_:completionHandler:)` and
/// `NSOpen/SavePanel.beginSheetModal(for:completionHandler:)`.
///
/// The presenter does not own state — each call returns control via
/// `async` so call sites can wait on the sheet's result inline without
/// juggling completion handlers.
@MainActor
enum SheetPresenter {
    // MARK: - View controller sheets

    /// Present `contentViewController` as a sheet attached to `parent`.
    ///
    /// `contentViewController` is wrapped in a transient `NSWindow` whose
    /// style mask defaults to `[.titled, .closable]`. The returned value
    /// is the `NSApplication.ModalResponse` passed to `endSheet(_:returnCode:)`
    /// — content view controllers typically call
    /// ``endSheet(_:returnCode:)`` on themselves to close.
    ///
    /// Sheet windows are not retained beyond the lifetime of the await; if
    /// the sheet's content view controller needs to outlive the sheet, the
    /// caller must own it.
    @discardableResult
    static func present(
        _ contentViewController: NSViewController,
        on parent: NSWindow,
        styleMask: NSWindow.StyleMask = [.titled, .closable],
        initialFirstResponder: NSView? = nil
    ) async -> NSApplication.ModalResponse {
        let sheetWindow = NSWindow(
            contentRect: .zero,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        sheetWindow.contentViewController = contentViewController
        if let initialFirstResponder {
            sheetWindow.initialFirstResponder = initialFirstResponder
        }

        return await withCheckedContinuation {
            (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            parent.beginSheet(sheetWindow) { response in
                continuation.resume(returning: response)
            }
        }
    }

    /// End a sheet started via ``present(_:on:styleMask:initialFirstResponder:)``.
    ///
    /// Call from inside the content view controller (e.g. a Cancel/OK button
    /// target) to dismiss the sheet with a specific response code.
    static func endSheet(
        _ sheetWindow: NSWindow,
        returnCode: NSApplication.ModalResponse
    ) {
        sheetWindow.sheetParent?.endSheet(sheetWindow, returnCode: returnCode)
    }

    // MARK: - File panels

    /// Outcome of an `NSOpenPanel` sheet.
    enum OpenPanelOutcome: Sendable {
        case cancelled
        case selected([URL])
    }

    /// Present an `NSOpenPanel` as a sheet attached to `parent`.
    static func openFile(
        in parent: NSWindow,
        allowedContentTypes: [UTType] = [],
        allowsMultipleSelection: Bool = false,
        canChooseDirectories: Bool = false,
        canChooseFiles: Bool = true,
        message: String? = nil,
        prompt: String? = nil
    ) async -> OpenPanelOutcome {
        let panel = NSOpenPanel()
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = allowsMultipleSelection
        if !allowedContentTypes.isEmpty {
            panel.allowedContentTypes = allowedContentTypes
        }
        if let message {
            panel.message = message
        }
        if let prompt {
            panel.prompt = prompt
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<OpenPanelOutcome, Never>) in
            panel.beginSheetModal(for: parent) { response in
                MainActor.assumeIsolated {
                    switch response {
                    case .OK:
                        continuation.resume(returning: .selected(panel.urls))
                    default:
                        continuation.resume(returning: .cancelled)
                    }
                }
            }
        }
    }

    /// Outcome of an `NSSavePanel` sheet.
    enum SavePanelOutcome: Sendable {
        case cancelled
        case selected(URL)
    }

    /// Present an `NSSavePanel` as a sheet attached to `parent`.
    static func saveFile(
        in parent: NSWindow,
        suggestedName: String? = nil,
        allowedContentTypes: [UTType] = [],
        message: String? = nil
    ) async -> SavePanelOutcome {
        let panel = NSSavePanel()
        if let suggestedName {
            panel.nameFieldStringValue = suggestedName
        }
        if !allowedContentTypes.isEmpty {
            panel.allowedContentTypes = allowedContentTypes
        }
        if let message {
            panel.message = message
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<SavePanelOutcome, Never>) in
            panel.beginSheetModal(for: parent) { response in
                MainActor.assumeIsolated {
                    switch response {
                    case .OK:
                        if let url = panel.url {
                            continuation.resume(returning: .selected(url))
                        } else {
                            continuation.resume(returning: .cancelled)
                        }
                    default:
                        continuation.resume(returning: .cancelled)
                    }
                }
            }
        }
    }
}
