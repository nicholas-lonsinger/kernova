import SwiftUI

/// Translucent overlay shown when a VM is live-paused (in memory but not running).
/// Displays a play button and "Paused" label over the frozen display.
struct VMPauseOverlay: View {
    var onResume: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onResume) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Resume")

            Text("Paused")
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
    /// Adds a pause overlay with animated opacity transition when `isPaused` is true.
    func vmPauseOverlay(isPaused: Bool, onResume: @escaping () -> Void) -> some View {
        overlay {
            if isPaused {
                VMPauseOverlay(onResume: onResume)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isPaused)
    }
}
