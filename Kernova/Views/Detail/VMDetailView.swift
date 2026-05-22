import SwiftUI

/// Detail area that switches between settings, console, install progress, and transition views based on VM status.
struct VMDetailView: View {
    @Bindable var instance: VMInstance
    @Bindable var viewModel: VMLibraryViewModel

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        if let preparing = instance.preparingState {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(preparing.operation.displayLabel)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch instance.status {
            case .stopped, .error:
                VMSettingsView(instance: instance, viewModel: viewModel, isReadOnly: false)

            case .initialBoot:
                VStack(spacing: 0) {
                    InitialBootBanner(instance: instance)
                    VMSettingsView(instance: instance, viewModel: viewModel, isReadOnly: false)
                }

            case .installing:
                if let installState = instance.installState {
                    MacOSInstallProgressView(installState: installState) {
                        viewModel.cancelInstallation(instance)
                    }
                } else {
                    transitionView
                }

            case _ where instance.status.hasActiveDisplay:
                // The AppKit `DetailRouterViewController` only routes here when
                // `detailPaneMode == .settings`; non-settings modes are served
                // by `ConsolePlaceholderViewController` directly.
                VMSettingsView(instance: instance, viewModel: viewModel, isReadOnly: true)

            default:
                transitionView
            }
        }
    }

    private var transitionView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(instance.status.displayName)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Banner shown above the settings panel for VMs whose initial boot hasn't
/// happened yet.
///
/// Adapts its subtitle to the persisted install context so the user knows what
/// Start will do (download + install vs. install from local IPSW vs. resume an
/// interrupted download).
private struct InitialBootBanner: View {
    let instance: VMInstance

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Initial Boot")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
    }

    private var subtitle: String {
        #if arch(arm64)
        guard let context = instance.configuration.installContext else {
            return "Click Start to install macOS."
        }
        switch context.source {
        case .downloadLatest:
            if instance.hasResumableInstallDownload {
                return "An interrupted download will resume when you click Start."
            }
            return "Click Start to download the latest macOS and install."
        case .localFile:
            let name = context.localIPSWURL?.lastPathComponent ?? "the selected IPSW"
            return "Click Start to install from \(name)."
        }
        #else
        return "Click Start to install macOS."
        #endif
    }
}
