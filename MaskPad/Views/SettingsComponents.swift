import AppKit
import SwiftUI

// Settings styling adapted from Kakey (MIT). See Resources/Licenses/Kakey.txt.
enum SettingsMetrics {
    static let windowSize = CGSize(width: 870, height: 630)
    static let sidebarWidth: CGFloat = 196
    static let sidebarTopInset: CGFloat = 52
    static let sidebarRowHeight: CGFloat = 34
    static let sidebarRowRadius: CGFloat = 8
    static let pageInset: CGFloat = 22
    static let pageTopInset: CGFloat = 40
    static let groupSpacing: CGFloat = 22
    static let groupRadius: CGFloat = 14
    static let rowInset: CGFloat = 18
    static let rowHeight: CGFloat = 50
    static let rowHeightWithDescription: CGFloat = 60
}

struct SettingsSidebarMaterial: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = reduceTransparency ? .windowBackground : .sidebar
    }
}

struct SettingsSidebarRow: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.sidebarRowHeight, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: SettingsMetrics.sidebarRowRadius))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.sidebarRowRadius, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.09) : .clear)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Groups have no visible heading: the sidebar supplies context, and each row names its setting.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let description: String?
    @ViewBuilder let control: Control
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, description: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                if let description {
                    Text(description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 20)
            control.fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 10)
        .frame(minHeight: description == nil ? SettingsMetrics.rowHeight : SettingsMetrics.rowHeightWithDescription)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.horizontal, SettingsMetrics.rowInset)
    }
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
            .font(.system(size: 11.5))
            .foregroundStyle(isWarning ? Color.orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.rowInset)
            .padding(.vertical, 10)
    }
}

struct SettingsButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(!isEnabled ? Color.secondary : configuration.role == .destructive ? .red : .primary)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(Color.secondary.opacity(configuration.isPressed ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(.separator.opacity(isEnabled ? 0.55 : 0.28))
            }
    }
}
