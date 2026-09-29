import Defaults
import SwiftUI

struct DashboardSettingsView: View {
    @Default(.batteryPercentageDisplayLocation) private var percentageLocation
    @Default(.showBatteryStateInStatusIcon) private var showState
    @Default(.showPowerSource) private var showPowerSource
    @Default(.showTimeTillDischarge) private var showTime
    @Default(.showBatteryMode) private var showMode
    @Default(.showBatteryTemperature) private var showTemperature
    @Default(.showBatteryHealth) private var showHealth
    @Default(.showPowerDistribution) private var showPowerDistribution

    var body: some View {
        SettingsPage {
            SettingsCard("菜单栏图标", subtitle: "保留插电与充电标记；放电时不显示箭头。预览中的 75% 为示例电量。") {
                SettingsRow("实时样式预览") {
                    BatteryIndicatorView(batteryLevel: 75, chargingMode: .pluggedIn,
                                         percentageDisplayLocation: percentageLocation, showState: showState)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(.primary.opacity(0.045), in: Capsule())
                }
                Divider()
                SettingsRow("电量百分比") {
                    Picker("电量百分比", selection: $percentageLocation) {
                        Text("隐藏").tag(PercentageDisplayLocation.hidden)
                        Text("图标旁").tag(PercentageDisplayLocation.nextToIcon)
                        Text("图标内").tag(PercentageDisplayLocation.insideIcon)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 225)
                }
                Divider()
                SettingsToggle("显示充电与低电量状态", isOn: $showState)
            }
            SettingsCard("面板 · 状态与预计") {
                SettingsToggle("充电状态", detail: "正在充电、正在放电或暂停充电。", isOn: $showMode)
                Divider()
                SettingsToggle("电源与适配器功率", detail: "显示当前连接协商的供电规格，例如 140 W。", isOn: $showPowerSource)
                Divider()
                SettingsToggle("续航 / 充电时间预计", detail: "根据实际状态切换；续航为平滑估计，不跟随瞬时功率跳动。", isOn: $showTime)
            }
            SettingsCard("面板 · 电池与功率") {
                SettingsToggle("电池健康", isOn: $showHealth)
                Divider()
                SettingsToggle("电池温度", isOn: $showTemperature)
                Divider()
                SettingsToggle("动态功率流向图", detail: "仅在面板打开时播放；遵循系统「减少动态效果」。", isOn: $showPowerDistribution)
            }
        }
    }
}
