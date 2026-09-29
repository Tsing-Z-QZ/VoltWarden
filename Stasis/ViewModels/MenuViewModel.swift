import AppKit
import Defaults
import Foundation
import Observation
import smc_power

@MainActor
@Observable
class MenuViewModel {

    private let batteryService:
        BatteryService

    private let chargeManager:
        ChargeManager

    // MARK: - Display Text

    var batteryPercentageText:
        String = "0%"

    var powerSourceText:
        String =
            String(
                localized: "Battery"
            )

    var timeRemainingText:
        String = "等待采样"

    var timeRemainingTitle: String = "断电预计"
    var timeRemainingHelp: String = "按当前真实剩余电量和最近几次整机功耗估算，与充电上限无关。"
    private var runtimeEstimator = UnpluggedRuntimeEstimator()
    private var chargeTimeEstimator = ChargeTimeEstimator()

    var batteryModeText:
        String =
            String(
                localized: "Unknown"
            )

    var batteryTemperatureText:
        String =
            String(
                localized: "Unknown"
            )

    var externalInputText:
        String = "0V @ 0A"

    var internalInputText:
        String = "0V @ 0A"

    var cycleCountText:
        String = "0"

    var batteryHealthText:
        String =
            String(
                localized: "Unknown"
            )

    // MARK: - Power Flow

    var displayPercentage:
        Int = 0

    var chargingMode:
        ChargingMode =
            .discharging

    var batteryPower:
        Double = 0

    var adapterPower:
        Double = 0

    var systemPower:
        Double = 0

    var powerSource:
        PowerSource =
            .battery

    var isCharging:
        Bool = false

    var isLowPowerModeEnabled:
        Bool = false

    var adapterConnected:
        Bool = false

    var adapterSpecificationText: String?

    var isMenuVisible = false

    // MARK: - Charge Manager State

    var chargeLimitOverrideActive:
        Bool
    {
        chargeManager
            .chargeLimitOverrideActive
    }

    var forceDischargeActive:
        Bool
    {
        chargeManager
            .forceDischargeActive
    }

    var manageChargingEnabled:
        Bool
    {
        Defaults[
            .manageCharging
        ]
    }

    var chargingControlAvailable:
        Bool
    {
        batteryService
            .deviceCapabilities
            .chargingControl
    }

    var calibrationActive:
        Bool
    {
        chargeManager
            .calibrationActive
    }

    var calibrationStatusText:
        String
    {
        switch chargeManager
            .calibrationPhase
        {
        case .idle:
            return String(
                localized:
                    "Calibration Ready"
            )

        case .chargingToFull:
            return String(
                localized:
                    "Calibration: Charging to 100%"
            )

        case .dischargingToTen:
            return String(
                localized:
                    "Calibration: Discharging to 10%"
            )

        case .chargingToFullAgain:
            return String(
                localized:
                    "Calibration: Recharging to 100%"
            )

        case .holdingAtFull:
            return String(
                localized:
                    "Calibration: Holding at 100%"
            )

        case .returningToLimit:
            return String(
                localized:
                    "Calibration: Returning to charge limit"
            )
        }
    }

    // MARK: - Tasks

    private var metricsObservation:
        Task<Void, Never>?

    private var settingsObservation:
        Task<Void, Never>?

    private var powerModeObservation:
        Task<Void, Never>?

    private var wakeObservation:
        Task<Void, Never>?

    // MARK: - Init

    init(
        batteryService:
            BatteryService,

        chargeManager:
            ChargeManager
    ) {

        self.batteryService =
            batteryService

        self.chargeManager =
            chargeManager

        startObservingMetrics()
        startObservingSettings()
        startObservingPowerMode()
        startObservingWake()
    }

    // MARK: - Observe Metrics

    private func startObservingMetrics() {

        metricsObservation =
            Task { [weak self] in

                guard let self else {
                    return
                }

                while !Task.isCancelled {

                    self.updateFormattedValues(
                        from:
                            self.batteryService
                            .metrics,

                        adapter:
                            self.batteryService
                            .adapterMetrics
                    )

                    await
                        withCheckedContinuation {
                            continuation in

                            withObservationTracking {

                                _ =
                                    self
                                    .batteryService
                                    .metrics

                                _ =
                                    self
                                    .batteryService
                                    .adapterMetrics

                                _ = self.batteryService.powerSampleDate
                                _ = self.chargeManager.chargeLimitOverrideActive
                                _ = self.chargeManager.forceDischargeActive

                            } onChange: {

                                Task {
                                    @MainActor in

                                    continuation
                                        .resume()
                                }
                            }
                        }
                }
            }
    }

    // MARK: - Observe Settings

    private func startObservingSettings() {

        settingsObservation =
            Task { [weak self] in

                for await _ in
                    Defaults.updates(
                        [
                            .useHardwarePercentage,
                            .chargeLimit,
                            .topUpSessionActive,
                            .manageCharging,
                            .calibrationPhase
                        ],
                        initial: false
                    )
                {
                    guard let self else {
                        return
                    }

                    self.updateFormattedValues(
                        from:
                            self.batteryService
                            .metrics,

                        adapter:
                            self.batteryService
                            .adapterMetrics
                    )
                }
            }
    }

    // MARK: - Low Power Mode

    private func startObservingWake() {
        wakeObservation = Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.didWakeNotification
            ) {
                self?.runtimeEstimator.noteWake()
            }
        }
    }

    private func startObservingPowerMode() {

        isLowPowerModeEnabled =
            ProcessInfo
            .processInfo
            .isLowPowerModeEnabled

        powerModeObservation =
            Task { [weak self] in

                let notifications =
                    NotificationCenter
                    .default
                    .notifications(
                        named:
                            .NSProcessInfoPowerStateDidChange,

                        object:
                            ProcessInfo
                            .processInfo
                    )

                for await _ in
                    notifications
                {
                    self?
                        .isLowPowerModeEnabled =
                        ProcessInfo
                        .processInfo
                        .isLowPowerModeEnabled
                }
            }
    }

    // MARK: - Controls

    func toggleChargeLimitOverride() {

        chargeManager
            .toggleChargeLimitOverride()
    }

    func toggleForceDischarge() {

        chargeManager
            .toggleForceDischarge()
    }

    func toggleCalibration() {

        if chargeManager
            .calibrationActive
        {
            chargeManager
                .cancelCalibration()
        } else {
            chargeManager
                .startCalibration()
        }
    }

    // MARK: - Update UI

    private func updateFormattedValues(
        from metrics:
            BatteryMetrics,

        adapter:
            AdapterMetrics
    ) {

        let useHardware =
            Defaults[
                .useHardwarePercentage
            ]

        let percentage =
            useHardware
            ? metrics.hardwareBatteryPercentage
            : metrics.batteryPercentage

        if displayPercentage != percentage {
            displayPercentage = percentage
        }

        batteryPercentageText =
            "\(percentage)%"

        // 先统一计算一次界面上应该显示的
        // Battery / Adapter / System Power。

        let flow =
            PowerFlowSnapshot.resolve(
                battery:
                    metrics,

                adapter:
                    adapter
            )

        batteryPower =
            flow.batteryPower

        adapterPower =
            flow.adapterPower

        systemPower =
            flow.systemPower

        if powerSource != flow.powerSource {
            powerSource = flow.powerSource
        }

        if chargingMode != flow.chargingMode {
            chargingMode = flow.chargingMode
        }

        isCharging =
            flow.chargingMode
            == .charging

        if adapterConnected != adapter.adapterConnected {
            adapterConnected = adapter.adapterConnected
        }

        // MARK: Power Source Text

        switch flow.powerSource {

        case .battery:
            powerSourceText =
                String(
                    localized:
                        "Battery"
                )

        case .acAdapter:
            powerSourceText =
                String(
                    localized:
                        "Power Adapter"
                )

        case .both:
            powerSourceText =
                String(
                    localized:
                        "Battery & Power Adapter"
                )
        }

        // MARK: Battery Mode Text

        switch flow.chargingMode {

        case .charging:

            batteryModeText =
                String(
                    localized:
                        "Charging"
                )

        case .pluggedIn:

            batteryModeText =
                String(
                    localized:
                        "Plugged In (Not Charging)"
                )

        case .discharging:
            batteryModeText =
                flow.powerSource == .both
                ? String(localized: "Adapter and Battery Supplying Power")
                : String(localized: "Battery Power")
        }

        // MARK: Remaining Time

        adapterSpecificationText = adapter.adapterConnected
            ? adapter.negotiatedWatts.map { "\($0) W" } : nil
        updateTimeRemainingText(metrics: metrics, flow: flow)

        // MARK: Temperature

        batteryTemperatureText =
            metrics.batteryTemperature
                > 0
            ? "\(metrics.batteryTemperature.formatted(.number.precision(.fractionLength(1))))°C"
            : String(
                localized:
                    "Unknown"
            )

        // MARK: Voltage / Current

        let voltageFormat =
            FloatingPointFormatStyle<Double>
            .number
            .precision(
                .fractionLength(2)
            )

        let currentFormat =
            FloatingPointFormatStyle<Double>
            .number
            .precision(
                .fractionLength(2)
            )

        // 当真实处于放电状态时，
        // Power Flow 视角下外部输入为 0。
        //
        // 如果你后面想保留
        // "虽然插着线，但没有供电"
        // 的适配器电压显示，
        // 这里可以再单独调整。

        if flow.powerSource == .battery
        {
            externalInputText =
                "0.00V @ 0.00A"
        } else {
            externalInputText =
                "\(adapter.adapterVoltage.formatted(voltageFormat))V @ \(adapter.adapterCurrent.formatted(currentFormat))A"
        }

        internalInputText =
            "\(metrics.batteryVoltage.formatted(voltageFormat))V @ \(metrics.batteryCurrent.formatted(currentFormat))A"

        // MARK: Other Metrics

        cycleCountText =
            "\(metrics.cycleCount)"

        batteryHealthText =
            metrics.batteryHealth
                > 0
            ? "\(Int(metrics.batteryHealth.rounded()))%"
            : String(
                localized:
                    "Unknown"
            )
    }

    // MARK: - Remaining Time

    private func updateTimeRemainingText(metrics: BatteryMetrics, flow: PowerFlowSnapshot) {
        runtimeEstimator.update(
            remainingCapacityMAh: metrics.remainingCapacityMAh,
            fullCapacityMAh: metrics.fullCapacityMAh,
            actualPercentage: metrics.hardwareBatteryPercentage,
            batteryVoltage: metrics.batteryVoltage,
            systemPower: flow.systemPower,
            sampleDate: batteryService.powerSampleDate
        )
        let phase = chargeManager.calibrationPhase
        let target: Int
        switch phase {
        case .chargingToFull, .chargingToFullAgain, .holdingAtFull:
            target = 100
        case .returningToLimit:
            target = Defaults[.calibrationOriginalLimit]
        default:
            target = chargeManager.effectiveChargeLimit
        }
        chargeTimeEstimator.update(metrics: metrics, target: manageChargingEnabled ? target : 100,
                                   sampleDate: batteryService.powerSampleDate)
        let kind = TimeEstimateKind.resolve(
            chargingMode: flow.chargingMode, adapterConnected: adapterConnected,
            actualPercentage: displayPercentage, effectiveTarget: target,
            manageCharging: manageChargingEnabled, calibrationDischarging: phase == .dischargingToTen,
            forceDischarging: forceDischargeActive
        )
        switch kind {
        case .charge(let target):
            timeRemainingTitle = target == 100 ? "预计充满" : "充至 \(target)%"
            timeRemainingText = chargeTimeEstimator.minutes.map { "约 " + formatTimeRemaining(minutes: $0) }
                ?? "等待充电开始"
            timeRemainingHelp = "根据实际充电电流估算到目标电量的时间；切换目标立即重算。接近满电会减速，实际时间可能更长。"
        case .runtime:
            timeRemainingTitle = adapterConnected ? "断电预计" : "预计续航"
            timeRemainingText = runtimeEstimator.minutes.map { "约 " + formatTimeRemaining(minutes: $0) }
                ?? "等待功耗数据"
            timeRemainingHelp = runtimeEstimator.isUsingPreviousReading && runtimeEstimator.minutes != nil
                ? "新采样暂不可用，保留上次估算；数据恢复后自动检查。"
                : "按真实剩余电量和平均功耗估算，不跟随实时功率跳动。最多每 5 分钟检查一次，变化达到 15% 且至少 10 分钟才更新；显示取约 5 分钟精度。"
        }
    }

    private func formatTimeRemaining(
        minutes: Int
    ) -> String {

        guard minutes >= 0 else {
            return ""
        }

        let hours =
            minutes / 60

        let mins =
            minutes % 60

        return String(
            format:
                "%02d:%02d",
            hours,
            mins
        )
    }

    // MARK: - Menu

    private func refreshPresentation() {
        updateFormattedValues(from: batteryService.metrics, adapter: batteryService.adapterMetrics)
    }

    func menuWillOpen() {

        isMenuVisible = true

        refreshPresentation()

        batteryService
            .enableFastPolling()
    }

    func menuDidClose() {

        isMenuVisible = false

        batteryService
            .disableFastPolling()
    }

    // MARK: - Quit

    func quit() {

        NSApplication
            .shared
            .terminate(nil)
    }

    // MARK: - Deinit

    deinit {

        MainActor
            .assumeIsolated {

                metricsObservation?
                    .cancel()

                settingsObservation?
                    .cancel()

                powerModeObservation?
                    .cancel()

                wakeObservation?
                    .cancel()
            }
    }
}
