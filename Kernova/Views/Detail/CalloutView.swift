import SwiftUI

/// Standard container for informational popover content.
///
/// Encapsulates the consistent typography, padding, and width used for callouts
/// across the app (e.g., `InfoButton`, `AttachmentIcon`).
struct CalloutBody<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .font(.callout)
        .padding()
        .frame(width: 340, alignment: .topLeading)
    }
}
