import Defaults
import SwiftUI

struct GeneralSettingsView: View {
    @Default(.launchAtLogin) private var launchAtLogin
    @Default(.disableNotifications) private var disableNotifications
    @Default(.showChargingStatusChangedNotification) private var showChargingStatusChangedNotification

    var body: some View {
        SettingsPage {
            SettingsCard("启动") {
                SettingsToggle("登录时启动", detail: "登录 Mac 后自动在菜单栏运行。", isOn: $launchAtLogin)
            }
            SettingsCard("通知", subtitle: "通知同时受 macOS「系统设置 → 通知」中的 VoltWarden 权限控制。") {
                SettingsToggle("允许通知", detail: "关闭后，VoltWarden 不再发送状态通知。",
                               isOn: Binding(get: { !disableNotifications }, set: { disableNotifications = !$0 }))
                Divider()
                SettingsToggle("充电状态发生变化", detail: "开始充电或停止充电时提醒。",
                               isOn: $showChargingStatusChangedNotification)
                    .disabled(disableNotifications)
            }
            SettingsNotice(text: "关闭电池面板不会退出 VoltWarden。退出 App 请使用面板底部的「退出」。", symbol: "menubar.rectangle")
        }
        .onChange(of: launchAtLogin) { _, enabled in
            LaunchAtLoginService.shared.setLaunchAtLogin(enabled)
        }
    }
}
