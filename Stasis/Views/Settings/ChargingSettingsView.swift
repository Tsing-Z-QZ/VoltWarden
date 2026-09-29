import AppKit
import Defaults
import SwiftUI
import os.log
import smc_power

struct ChargingSettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Default(.manageCharging) private var manageCharging
    @Default(.chargeLimit) private var chargeLimit
    @Default(.automaticDischarge) private var automaticDischarge
    @Default(.calibrationPhase) private var calibrationPhase
    @State private var chargeLimitDraft = ChargeLimitDraft()
    @State private var helperManager = ChargingHelperManager.shared
    @State private var installError: String?
    private let capabilities: DeviceCapabilities
    private let chargeManager: ChargeManager?
    private let logger = Logger(subsystem: "com.srimanachanta.stasis", category: "ChargingSettingsView")

    init(capabilities: DeviceCapabilities, chargeManager: ChargeManager? = nil) {
        self.capabilities = capabilities
        self.chargeManager = chargeManager
    }

    private var topUpActive: Bool { chargeManager?.chargeLimitOverrideActive == true }
    private var limitEditingEnabled: Bool { manageCharging && !topUpActive && calibrationPhase == .idle }
    private var displayedLimit: Int {
        topUpActive ? 100 : (chargeLimitDraft.isEditing ? Int(chargeLimitDraft.value.rounded()) : chargeLimit)
    }

    var body: some View {
        SettingsPage {
            SettingsCard("充电管理", subtitle: "首次启用需要管理员授权，并在 macOS「登录项与扩展」中允许后台服务。") {
                SettingsToggle("管理充电", detail: "由本机特权 helper 执行充电控制。",
                               isOn: Binding(get: { manageCharging }, set: toggleManageCharging))
                    .disabled(helperManager.helperStatus == .requiresApproval)
                if helperManager.helperStatus == .requiresApproval {
                    Divider()
                    SettingsRow("等待系统批准", detail: "批准后点击「重新检查」。") {
                        HStack {
                            Button("打开系统设置", action: openLoginItemsSettings).settingsButton(prominent: true)
                            Button("重新检查", action: checkApprovalStatus).settingsButton()
                        }
                    }
                }
            }

            SettingsCard("日常充电上限", subtitle: "拖动时只预览，松手后提交。降低目标不会让真实电量瞬间降低，也不会直接改变断电续航。") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(topUpActive ? "本次充至满电" : "目标电量").font(.system(size: 13))
                            Text(topUpActive ? "日常上限仍保存为 \(chargeLimit)%" : "50% – 100%")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(displayedLimit)%")
                            .font(.system(size: 34, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.tint)
                            .contentTransition(.numericText())
                    }
                    Slider(
                        value: Binding(
                            get: { chargeLimitDraft.isEditing ? chargeLimitDraft.value : Double(topUpActive ? 100 : chargeLimit) },
                            set: { value in
                                guard limitEditingEnabled else { return }
                                if let committed = chargeLimitDraft.update(value) {
                                    chargeLimit = committed
                                }
                            }
                        ), in: 50...100, step: 1,
                        onEditingChanged: { editing in
                            if editing {
                                chargeLimitDraft.begin(current: chargeLimit)
                            } else if let committed = chargeLimitDraft.finish(enabled: limitEditingEnabled) {
                                chargeLimit = committed
                            }
                        }
                    )
                    .focusEffectDisabled()
                    .disabled(!limitEditingEnabled)
                    .accessibilityLabel("充电上限")
                    HStack {
                        Text("50%")
                        Spacer()
                        Text("100%")
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 18)
            }

            SettingsCard("临时充满 · Top Up", subtitle: "临时提高到 100%，不覆盖日常上限；取消或拔掉适配器后恢复日常目标。") {
                SettingsRow(topUpActive ? "本次充满已开启" : "为外出准备满电",
                            detail: topUpActive ? "当前有效上限 100%，充满预计显示在电池面板。" : "打开后立即切换到「预计充满」。") {
                    Button(topUpActive ? "恢复 \(chargeLimit)% 上限" : "本次充至 100%") {
                        chargeManager?.toggleChargeLimitOverride()
                    }
                    .settingsButton(prominent: !topUpActive)
                    .disabled(chargeManager == nil || (!topUpActive && (!manageCharging || chargeManager?.isAdapterConnected != true || calibrationPhase != .idle)))
                }
            }

            SettingsCard("降低上限时") {
                SettingsToggle("自动放电至新上限",
                               detail: "当前电量高于目标时使用电池，降至目标后恢复适配器供电。",
                               isOn: $automaticDischarge)
                    .disabled(!manageCharging || !capabilities.adapterControl)
            }

            if calibrationPhase != .idle {
                SettingsNotice(text: "校准正在运行，充电上限暂时由校准流程控制。可在「养护与保护」中停止。",
                               symbol: "arrow.triangle.2.circlepath", tint: .orange)
            } else if !manageCharging {
                SettingsNotice(text: "充电管理已关闭。上限值会保留，但当前不会应用到系统。", symbol: "pause.circle")
            }
        }
        .onChange(of: limitEditingEnabled) { _, enabled in
            if !enabled { chargeLimitDraft.cancel() }
        }
        .onDisappear { chargeLimitDraft.cancel() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: topUpActive)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: helperManager.helperStatus)
        .alert("充电服务操作失败", isPresented: Binding(
            get: { installError != nil }, set: { if !$0 { installError = nil } }
        )) {
            Button("好", role: .cancel) { installError = nil }
        } message: {
            Text(installError ?? "")
        }
    }
    private func toggleManageCharging(
        _ enabled: Bool
    ) {

        do {

            if enabled {

                try helperManager
                    .install()

                if helperManager
                    .helperStatus
                    ==
                    .installed
                {
                    manageCharging =
                        true

                } else if
                    helperManager
                    .helperStatus
                    ==
                    .requiresApproval
                {
                    openLoginItemsSettings()
                }

            } else {
                Task {
                    do {
                        try await chargeManager?.prepareForHelperRemoval()
                        try helperManager.uninstall()
                        manageCharging = false
                    } catch {
                        installError = error.localizedDescription
                    }
                }
            }

        } catch {

            logger.error(
                """
                Failed to \
                \(enabled ? "install" : "uninstall") \
                charging helper: \(error)
                """
            )

            installError =
                error.localizedDescription
        }
    }

    private func checkApprovalStatus() {

        helperManager
            .refreshStatus()

        if helperManager
            .helperStatus
            ==
            .installed
        {
            manageCharging =
                true
        }
    }

    private func openLoginItemsSettings() {

        guard
            let url =
                URL(
                    string:
                        """
                        x-apple.systempreferences:com.apple.LoginItems-Settings.extension
                        """
                )
        else {
            return
        }

        NSWorkspace.shared
            .open(url)
    }
}
