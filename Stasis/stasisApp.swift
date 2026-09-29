import SwiftUI

@main
struct StasisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            StasisSettingsScene(appDelegate: appDelegate)
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("打开电池面板") { appDelegate.showDashboard() }
            }
        }
    }
}

private struct StasisSettingsScene: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        if let settings = appDelegate.settingsContent {
            settings
        } else {
            ProgressView("正在读取电池…")
                .frame(width: 400, height: 240)
        }
    }
}
