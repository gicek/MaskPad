import SwiftUI

/// Shared presentation for the real mask and its settings preview.
struct MaskMessageContent: View {
    let message: String
    let onUnlock: () -> Void

    var body: some View {
        VStack(spacing: 36) {
            Text(verbatim: message)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .frame(maxWidth: 760)
            Button(action: onUnlock) {
                Text(L("Unlock"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 40)
    }
}
