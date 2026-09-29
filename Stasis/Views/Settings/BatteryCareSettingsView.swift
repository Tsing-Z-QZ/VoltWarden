import Defaults
import SwiftUI
import smc_power

struct BatteryCareSettingsView: View {
    let capabilities: DeviceCapabilities
    let chargeManager: ChargeManager?
    @Default(.manageCharging) private var manageCharging
    @Default(.automaticMonthlyCalibration) private var monthlyCalibration
    @Default(.lastCalibrationDate) private var lastCalibrationDate
    @Default(.lastCalibrationAttemptDate) private var lastCalibrationAttemptDate
    @Default(.calibrationPhase) private var calibrationPhase
    @Default(.disableSleepUntilChargeLimit) private var preventSleep
    @Default(.sailingMode) private var sailingMode
    @Default(.sailingModeLimit) private var sailingLimit
    @Default(.enableHeatProtectionMode) private var heatProtection
    @Default(.heatProtectionLimit) private var temperatureLimit
    @Default(.manageMagSafeLED) private var manageLED
    @State private var showCalibrationConfirmation = false

    private var calibrationActive: Bool { calibrationPhase != .idle }
    private var legacyControlAvailable: Bool { chargeManager?.usesNativeChargeLimit != true && capabilities.chargingControl }
    private var nextCalibrationDate: Date? {
        guard let anchor = [lastCalibrationDate, lastCalibrationAttemptDate].compactMap({ $0 }).max() else { return nil }
        return Calendar.current.date(byAdding: .month, value: 1, to: anchor)
    }

    private var calibrationStatus: String {
        switch calibrationPhase {
        case .idle: "未运行"
        case .chargingToFull: "正在充至 100%"
        case .dischargingToTen: "正在放电至 10%"
        case .chargingToFullAgain: "正在再次充至 100%"
        case .holdingAtFull: "满电保持一小时"
        case .returningToLimit: "正在恢复日常上限"
        }
    }

    var body: some View {
        SettingsPage {
            SettingsCard("电池校准", subtitle: "校准会完整充放电，需要长时间接通电源；它不等于修复电池健康。不需要频繁运行。") {
                SettingsRow("手动校准", detail: calibrationStatus) {
                    Button(calibrationActive ? "停止校准" : "开始校准") {
                        if calibrationActive {
                            chargeManager?.cancelCalibration()
                        } else {
                            showCalibrationConfirmation = true
                        }
                    }
                    .settingsButton()
                    .disabled(chargeManager == nil || (!calibrationActive && (!manageCharging || chargeManager?.isAdapterConnected != true)))
                }
                Divider()
                SettingsToggle("每月自动校准", detail: "到期后，在接通电源的合适时机开始。",
                               isOn: Binding(get: { monthlyCalibration }, set: { enabled in
                                   monthlyCalibration = enabled
                                   if enabled && lastCalibrationDate == nil { lastCalibrationDate = Date() }
                               }))
                    .disabled(!manageCharging)
                if monthlyCalibration, let date = nextCalibrationDate {
                    Divider()
                    SettingsRow("下次自动校准") {
                        Text(date <= Date() ? "已到期，接通电源后执行" : date.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCard("睡眠", subtitle: "合盖进入睡眠或拔掉电源后会暂停无效上限重试。此开关只影响达到目标前的闲置睡眠，不应阻止合盖睡眠。") {
                SettingsToggle("达到上限前暂缓闲置睡眠", detail: "通常建议关闭，避免插电闲置时不必要地保持唤醒。",
                               isOn: $preventSleep)
                    .disabled(!manageCharging)
            }

            SettingsCard("兼容设备的附加保护", subtitle: legacyControlAvailable
                         ? "仅在设备支持充电开关时可用。"
                         : "本机使用原生上限或不支持传统充电开关，巡航选项不会生效；灰色选项保留原设置。") {
                SettingsToggle("巡航模式", detail: "到达上限后，下降一定电量才恢复充电。", isOn: $sailingMode)
                    .disabled(!manageCharging || !legacyControlAvailable)
                if sailingMode && legacyControlAvailable {
                    Divider()
                    SettingsRow("恢复充电的下降幅度") {
                        Stepper("\(sailingLimit)%", value: $sailingLimit, in: 1...20)
                            .frame(width: 110)
                    }.disabled(!manageCharging)
                }
                Divider()
                SettingsToggle("高温暂停充电", detail: "需要设备支持充电开关；系统自带的温度保护不受此设置影响。",
                               isOn: $heatProtection)
                    .disabled(!manageCharging || !capabilities.chargingControl)
                if heatProtection && capabilities.chargingControl {
                    Divider()
                    SettingsRow("温度阈值") {
                        Stepper("\(temperatureLimit)°C", value: $temperatureLimit, in: 30...50)
                            .frame(width: 110)
                    }.disabled(!manageCharging)
                }
            }

            if capabilities.hasMagSafe {
                SettingsCard("MagSafe") {
                    SettingsToggle("同步充电指示灯", detail: capabilities.magsafeLEDControl ? "根据充电状态设置指示灯颜色。" : "此设备未报告指示灯控制支持。",
                                   isOn: $manageLED)
                        .disabled(!manageCharging || !capabilities.magsafeLEDControl)
                }
            }
        }
        .confirmationDialog("开始完整电池校准？", isPresented: $showCalibrationConfirmation, titleVisibility: .visible) {
            Button("开始校准") { chargeManager?.startCalibration() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("流程：充至 100% → 放至 10% → 再充满 → 保持一小时 → 恢复日常上限。请保持适配器连接。")
        }
    }
}
