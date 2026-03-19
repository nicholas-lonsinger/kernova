import SwiftUI

/// Translucent overlay shown when a VM is live-paused (in memory but not running).
/// Displays a play button and "Paused" label over the frozen display.
struct VMPauseOverlay: View {
    var onResume: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            VStack(spacing: 12) {
                Button {
                    onResume()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Text("Paused")
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
        }
        .allowsHitTesting(true)
    }
}
