import SwiftUI
import AppKit

/// SwiftUI content view for the per-VM clipboard sharing window.
///
/// Presents two panels:
/// - **From Guest**: read-only display of the latest text the guest copied to its clipboard
/// - **To Guest**: editable text field where the user can type or paste text to send to the guest
///
/// Clipboard data flows through `SpiceClipboardService` rather than the host `NSPasteboard`,
/// giving the user explicit control over what enters and leaves each VM.
struct ClipboardContentView: View {

    let instance: VMInstance

    @State private var textToSend: String = ""

    private var service: SpiceClipboardService? {
        instance.clipboardService
    }

    var body: some View {
        VStack(spacing: 0) {
            fromGuestSection
            Divider()
            toGuestSection
            Divider()
            statusBar
        }
        .frame(minWidth: 320, idealWidth: 480, minHeight: 280, idealHeight: 400)
    }

    // MARK: - From Guest

    @ViewBuilder
    private var fromGuestSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("From Guest", systemImage: "arrow.down.doc")
                    .font(.headline)
                Spacer()
                Button("Copy to Host Clipboard") {
                    copyToHostClipboard()
                }
                .disabled(service?.guestClipboardText.isEmpty ?? true)
            }

            ScrollView {
                Text(service?.guestClipboardText ?? "")
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding()
    }

    // MARK: - To Guest

    @ViewBuilder
    private var toGuestSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("To Guest", systemImage: "arrow.up.doc")
                    .font(.headline)
                Spacer()
                Button("Send to Guest") {
                    sendToGuest()
                }
                .disabled(textToSend.isEmpty || !(service?.isConnected ?? false))
            }

            TextEditor(text: $textToSend)
                .font(.system(.body, design: .monospaced))
                .frame(maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding()
    }

    // MARK: - Status Bar

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(service?.isConnected ?? false ? .green : .secondary)
                .frame(width: 8, height: 8)

            Text(service?.isConnected ?? false ? "Connected" : "Waiting for guest agent")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func copyToHostClipboard() {
        guard let text = service?.guestClipboardText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func sendToGuest() {
        guard !textToSend.isEmpty else { return }
        service?.sendToGuest(textToSend)
        textToSend = ""
    }
}
