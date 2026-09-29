import Defaults
import SwiftUI

struct AdvancedSettingsView: View {
    @Default(.useHardwarePercentage) private var useHardwarePercentage
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }

    var body: some View {
        SettingsPage {
            SettingsCard("读数来源", subtitle: "充电上限使用选定的百分比。断电续航始终优先使用真实剩余容量，不会把上限当作当前电量。") {
                SettingsToggle("使用硬件原始百分比", detail: "关闭时使用 macOS 校准后的电量，通常更接近系统菜单栏。",
                               isOn: $useHardwarePercentage)
            }
            SettingsCard("本机诊断", subtitle: "日志保存在 ~/Library/Logs/Stasis，并自动轮转。分享日志前请检查设备信息。") {
                SettingsRow("控制日志", detail: "包含目标提交、系统确认、睡眠与唤醒记录。") {
                    Button("查看日志", systemImage: "doc.text.magnifyingglass") {
                        ControlDiagnostics.shared.show()
                    }
                    .settingsButton()
                }
            }
            SettingsNotice(text: "设定上限和系统实际确认是两件事。诊断过充时，请同时检查 NATIVE_REQUEST 与 NATIVE_VERIFIED；界面目标本身不代表系统已经执行。",
                           symbol: "checkmark.shield")
            SettingsCard("关于 VoltWarden") {
                SettingsRow("版本") { Text(version).foregroundStyle(.secondary).textSelection(.enabled) }
                Divider()
                SettingsRow("构建") { Text(build).foregroundStyle(.secondary).textSelection(.enabled) }
                Divider()
                SettingsRow("运行方式", detail: "菜单栏 App + 本机特权充电 helper。") {
                    Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                }
            }
        }
    }
}
