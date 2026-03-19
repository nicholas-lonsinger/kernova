import SwiftUI

/// Translucent overlay shown during VM state transitions (suspending/restoring).
/// Displays a spinner and status label over the frozen or incoming display.
struct VMTransitionOverlay: View {
    var label: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)

            Text(label)
                .font(.title2)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .shadow(radius: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

extension View {
    /// Adds a transition overlay with animated opacity when the VM is saving or restoring.
    func vmTransitionOverlay(status: VMStatus) -> some View {
        let label: String? = switch status {
        case .saving: "Suspending…"
        case .restoring: "Restoring…"
        default: nil
        }
        return overlay {
            if let label {
                VMTransitionOverlay(label: label)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: status)
    }
}
