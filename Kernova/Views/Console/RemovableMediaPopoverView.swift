import SwiftUI

/// Popover content for managing runtime USB mass storage devices on a running VM.
/// Shown from the "Removable Media" toolbar button.
struct RemovableMediaPopoverView: View {
    @Bindable var instance: VMInstance
    @Bindable var viewModel: VMLibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if instance.attachedUSBDevices.isEmpty {
                Text("No removable media attached")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ForEach(instance.attachedUSBDevices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.readOnly ? "lock.fill" : "externaldrive.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        Text(device.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button {
                            viewModel.detachUSBDevice(device, from: instance)
                        } label: {
                            Image(systemName: "eject.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Eject \(device.displayName)")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
            }

            Divider()

            Button {
                browseAndAttach()
            } label: {
                Label("Attach Disc Image...", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .padding()

            Text("Removable media is ejected when the VM stops.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal)
                .padding(.bottom, 12)
        }
        .frame(width: 280)
    }

    private func browseAndAttach() {
        guard let url = NSOpenPanel.browseDiskImages(
            message: "Select a disk image to attach as removable media"
        ).first else { return }
        viewModel.attachUSBDevice(
            diskImagePath: url.path(percentEncoded: false),
            readOnly: true,
            to: instance
        )
    }
}
