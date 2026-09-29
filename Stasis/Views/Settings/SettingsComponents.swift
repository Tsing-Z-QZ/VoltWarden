import SwiftUI

struct SettingsPage<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isScrolled = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GeometryReader { geometry in
                    Color.clear.preference(key: SettingsScrollOffsetKey.self,
                                           value: geometry.frame(in: .named("settingsScroll")).minY)
                }
                .frame(height: 0)
                content()
            }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .coordinateSpace(name: "settingsScroll")
        .onPreferenceChange(SettingsScrollOffsetKey.self) { isScrolled = $0 < 20 }
        .overlay(alignment: .top) {
            if isScrolled {
                Rectangle()
                    .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                                             : AnyShapeStyle(.ultraThinMaterial))
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom))
                    .frame(height: 36)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct SettingsScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 24
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct SettingsCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let title: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.leading, 4)
            VStack(spacing: 0, content: content)
                .padding(.horizontal, 16)
                .background(
                    Color(nsColor: .controlBackgroundColor).opacity(reduceTransparency ? 1 : 0.72),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: () -> Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 13)
        .frame(minHeight: 46)
    }
}

struct SettingsToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
                .accessibilityLabel(title)
        }
    }
}

struct SettingsNotice: View {
    let text: String
    var symbol: String = "info.circle"
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }
}

extension View {
    func settingsButton(prominent: Bool = false) -> some View {
        controlSize(.regular)
            .buttonBorderShape(.capsule)
            .modifier(SettingsButtonModifier(prominent: prominent))
    }
}

private struct SettingsButtonModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
