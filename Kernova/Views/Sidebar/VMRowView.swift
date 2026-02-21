import SwiftUI

/// A single row in the sidebar representing a virtual machine.
struct VMRowView: View {
    let instance: VMInstance
    var isRenaming: Bool = false
    var onCommitRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}

    @State private var editingName: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $editingName)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .focused($isTextFieldFocused)
                        .onSubmit {
                            onCommitRename(editingName)
                        }
                        .onExitCommand {
                            onCancelRename()
                        }
                } else {
                    Text(instance.name)
                        .font(.body)
                        .lineLimit(1)
                }

                Text(instance.configuration.guestOS.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(instance.status.statusColor)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 2)
        .onChange(of: isRenaming) { _, renaming in
            if renaming {
                editingName = instance.name
                isTextFieldFocused = true
            }
        }
        .onChange(of: isTextFieldFocused) { _, focused in
            if !focused && isRenaming {
                onCommitRename(editingName)
            }
        }
    }

    private var iconName: String {
        switch instance.configuration.guestOS {
        case .macOS: "macwindow"
        case .linux: "terminal"
        }
    }
}
