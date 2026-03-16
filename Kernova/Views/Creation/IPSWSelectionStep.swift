import SwiftUI
import UniformTypeIdentifiers

/// Step 2 (macOS): Choose an IPSW restore image source.
struct IPSWSelectionStep: View {
    @Bindable var creationVM: VMCreationViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text("macOS Restore Image")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Choose how to obtain the macOS restore image (IPSW) for installation.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                sourceButton(
                    title: "Download Latest",
                    description: "Download the latest compatible macOS restore image from Apple.",
                    icon: "arrow.down.circle",
                    isSelected: creationVM.ipswSource == .downloadLatest
                ) {
                    creationVM.ipswSource = .downloadLatest
                    if creationVM.ipswDownloadPath == nil {
                        creationVM.ipswDownloadPath = VMCreationViewModel.defaultIPSWDownloadPath
                    }
                }

                sourceButton(
                    title: "Choose Local File",
                    description: "Select an IPSW file already on your Mac.",
                    icon: "folder",
                    isSelected: creationVM.ipswSource == .localFile
                ) {
                    selectIPSWFile()
                }
            }

            if creationVM.ipswSource == .downloadLatest, let path = creationVM.ipswDownloadPath {
                pathBadge(path: path) {
                    selectDownloadDestination()
                }

                if creationVM.shouldShowOverwriteWarning {
                    overwriteWarningBanner
                }
            }

            if creationVM.ipswSource == .localFile, let path = creationVM.ipswPath {
                pathBadge(path: path) {
                    selectIPSWFile()
                }
            }
        }
    }

    private func pathBadge(path: String, changeAction: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
            Text(abbreviateWithTilde(path))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Button("Change…") {
                changeAction()
            }
            .font(.caption)
            .buttonStyle(.link)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private var overwriteWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)

            Text("A file already exists at this location. It will be replaced when downloading.")
                .font(.callout)

            Spacer()

            Button("Use Existing File") {
                creationVM.useExistingDownloadFile()
            }
            .controlSize(.small)

            Button("Download & Replace") {
                creationVM.confirmOverwrite()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(0.1))
                .strokeBorder(Color.yellow.opacity(0.3), lineWidth: 1)
        }
    }

    private func sourceButton(
        title: String,
        description: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding()
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func selectDownloadDestination() {
        let panel = NSSavePanel()
        panel.title = "Choose Download Location"

        // Pre-fill from current path if available
        if let currentPath = creationVM.ipswDownloadPath {
            let currentURL = URL(fileURLWithPath: currentPath)
            panel.directoryURL = currentURL.deletingLastPathComponent()
            panel.nameFieldStringValue = currentURL.lastPathComponent
        } else {
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.nameFieldStringValue = "RestoreImage.ipsw"
        }
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw")!]

        if panel.runModal() == .OK, let url = panel.url {
            creationVM.ipswDownloadPath = url.path(percentEncoded: false)
        }
    }

    private func selectIPSWFile() {
        let panel = NSOpenPanel()
        panel.title = "Select macOS Restore Image"
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw")!]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            creationVM.ipswSource = .localFile
            creationVM.ipswPath = url.path(percentEncoded: false)
        }
    }

    private func abbreviateWithTilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
