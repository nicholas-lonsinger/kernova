import SwiftUI

/// Step 1: Select the guest operating system type.
struct OSSelectionStep: View {
    @Bindable var creationVM: VMCreationViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text("Choose Operating System")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select the type of operating system you want to run in your virtual machine.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 20) {
                osCard(for: .macOS, icon: "apple.logo", description: "Run macOS in a virtual machine on Apple Silicon.")
                osCard(for: .linux, icon: "terminal.fill", description: "Run Linux distributions using EFI or direct kernel boot.")
            }
            .padding(.top, 8)
        }
    }

    private func osCard(for os: VMGuestOS, icon: String, description: String) -> some View {
        Button {
            creationVM.selectedOS = os
        } label: {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 36))
                    .foregroundStyle(creationVM.selectedOS == os ? Color.accentColor : .secondary)

                Text(os.displayName)
                    .font(.headline)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(height: 36)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(creationVM.selectedOS == os ? Color.accentColor.opacity(0.1) : Color.clear)
                    .strokeBorder(creationVM.selectedOS == os ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
