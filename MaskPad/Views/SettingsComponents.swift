import SwiftUI

/// A section: small header plus a rounded card, matching System Settings. Content handles its own row dividers.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        // Type scale matches System Settings: 13pt bold headers, 13pt rows, 11pt notes.
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard()
        }
    }
}

/// Card background. Through macOS 15 the window is light gray and `controlBackgroundColor` is white, so the card stands out.
/// From macOS 26 the window is near-white too, so use the translucent gray System Settings uses, without a stroke.
private struct SettingsCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        if #available(macOS 26, *) {
            content.background(.quinary, in: shape)
        } else {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
        }
    }
}

extension View {
    func settingsCard() -> some View {
        modifier(SettingsCardModifier())
    }
}

/// A row: title on the left, control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title).font(.body)
            Spacer(minLength: 12)
            control
        }
    }
}

struct SettingsDivider: View {
    var body: some View { Divider().opacity(0.6) }
}

struct SettingsNote: View {
    let text: String
    let isWarning: Bool

    init(_ text: String, isWarning: Bool = false) {
        self.text = text
        self.isWarning = isWarning
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(isWarning ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
