import SwiftUI
import smc_power

enum SettingsTab: String, CaseIterable, Identifiable {
    case charging, care, appearance, general, diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .charging: "充电控制"
        case .care: "养护与保护"
        case .appearance: "外观与面板"
        case .general: "通用与通知"
        case .diagnostics: "高级与诊断"
        }
    }

    var subtitle: String {
        switch self {
        case .charging: "设置日常上限，也为临时出行留足电量。"
        case .care: "按需使用校准与保护，了解每一项控制的边界。"
        case .appearance: "原生菜单栏图标，只保留你关心的信息。"
        case .general: "让 VoltWarden 安静地融入日常使用。"
        case .diagnostics: "查看读数来源、版本与本机控制记录。"
        }
    }

    var icon: String {
        switch self {
        case .charging: "battery.100percent.bolt"
        case .care: "heart"
        case .appearance: "menubar.rectangle"
        case .general: "gearshape"
        case .diagnostics: "slider.horizontal.3"
        }
    }
}

struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: SettingsTab = .charging
    private let capabilities: DeviceCapabilities
    private let chargeManager: ChargeManager?

    init(capabilities: DeviceCapabilities, chargeManager: ChargeManager? = nil) {
        self.capabilities = capabilities
        self.chargeManager = chargeManager
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "battery.100percent.bolt")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 42, height: 42)
                        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("VoltWarden").font(.system(size: 17, weight: .semibold))
                        Text("电池与电源").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)

                List(SettingsTab.allCases, selection: $selectedTab) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .font(.system(size: 13))
                        .padding(.vertical, 5)
                        .tag(tab)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 205, ideal: 215, max: 240)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: selectedTab.icon)
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 48, height: 48)
                        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selectedTab.title).font(.title2.weight(.bold))
                        Text(selectedTab.subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .accessibilityElement(children: .combine)

                Group {
                    switch selectedTab {
                    case .charging:
                        ChargingSettingsView(capabilities: capabilities, chargeManager: chargeManager)
                    case .care:
                        BatteryCareSettingsView(capabilities: capabilities, chargeManager: chargeManager)
                    case .appearance:
                        DashboardSettingsView()
                    case .general:
                        GeneralSettingsView()
                    case .diagnostics:
                        AdvancedSettingsView()
                    }
                }
                .id(selectedTab)
                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 5)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: selectedTab)
        .frame(minWidth: 820, idealWidth: 900, minHeight: 590, idealHeight: 680)
    }
}
