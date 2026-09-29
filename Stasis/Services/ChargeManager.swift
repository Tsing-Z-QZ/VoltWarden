import AppKit
import Defaults
import Foundation
import IOKit.pwr_mgt
import Observation
import UserNotifications
import os.log
import smc_power

@MainActor
@Observable
class ChargeManager {

    // MARK: - Services

    private let batteryService: BatteryService

    // macOS 原生 Manual Charge Limit
    //
    // PowerUI 负责 enable / disable MCL，
    // privileged helper 负责写入 75 / 80 / 100 等目标。
    private let nativeChargeLimitCoordinator:
        NativeChargeLimitCoordinator

    private var nativeChargeLimitAvailable: Bool {
        nativeChargeLimitCoordinator.isAvailable
    }

    // MARK: - Observation

    private var metricsObservation: Task<Void, Never>?
    private var settingsObservation: Task<Void, Never>?
    private var calibrationTimerTask: Task<Void, Never>?
    private var sleepObservationTask: Task<Void, Never>?
    private var wakeObservationTask: Task<Void, Never>?

    // MARK: - Command Queue

    private var controlTask: Task<Void, Never>?
    private var controlRetryTask: Task<Void, Never>?
    private var ledControlTask: Task<Void, Never>?
    private var controlRevision = 0
    private var blockedControlRevision: Int?
    private var runtimeChargingControlUnsupported = false
    private var preparingForHelperRemoval = false

    private var desiredChargingCommand: Bool?
    private var desiredAdapterCommand: Bool?
    private var desiredLEDCommand: MagSafeLEDState?

    private var appliedChargingCommand: Bool?
    private var appliedAdapterCommand: Bool?
    private var appliedLEDCommand: MagSafeLEDState?

    // MARK: - Policy State

    private var lastAdapterConnected: Bool?
    private var lastManageChargingEnabled: Bool?
    private var lastRequestedLimit: Int?
    private var lastAutomaticDischargeEnabled: Bool?
    private var lastUseHardwarePercentage: Bool?
    private var lastCapabilitiesMask: Int?

    private var hasReachedChargeLimit = false

    /*
     Automatic Discharge 必须是一个“过程状态”。

     例如：

     当前 85%
     用户把上限改成 75%
     ↓
     automaticDischargeActive = true
     ↓
     放到 75%
     ↓
     automaticDischargeActive = false
     ↓
     Adapter ON
     Charging OFF

     这样正常充到 75 以后即使显示短暂变化，
     也不会突然开始反向放电。
     */
    private var automaticDischargeActive = false

    // 用户刚刚降低充电上限时，macOS / powerd 可能仍短暂执行旧的
    // Native MCL。例如 75 -> 80 -> 75，最后一次切回 75 时电池可能
    // 仍然沿着旧 80% 目标继续充几秒。
    //
    // 这里保留一个短暂的“防反冲窗口”：
    // 如果目标降低后的 60 秒内电量重新超过新目标，就重新启动
    // Automatic Discharge，而不是等电池一路冲高后才处理。
    private var loweredTargetGuardLimit: Int?
    private var loweredTargetGuardUntil: Date?

    private let loweredTargetGuardDuration: TimeInterval = 60

    private var lastNotifiedChargingState: Bool?

    private var sleepPauseActive = false
    private let sleepAssertionHandler: ((Bool) -> Void)?
    private let record: (String, String) -> Void

    // MARK: - Public State

    private(set) var chargeLimitOverrideActive = Defaults[.topUpSessionActive]
    private(set) var forceDischargeActive = false

    var isAdapterConnected: Bool { batteryService.controlState.adapterConnected }
    var usesNativeChargeLimit: Bool { nativeChargeLimitAvailable }

    var effectiveChargeLimit: Int {
        chargeLimitOverrideActive
            ? 100
            : Defaults[.chargeLimit]
    }

    private var nativeLimitForCurrentPhase: Int {
        switch calibrationPhase {
        case .returningToLimit:
            return Defaults[.calibrationOriginalLimit]
        case .idle:
            return effectiveChargeLimit
        default:
            return 100
        }
    }

    var calibrationPhase: CalibrationPhase {
        Defaults[.calibrationPhase]
    }

    var calibrationActive: Bool {
        calibrationPhase != .idle
    }

    // MARK: - Sleep

    private var sleepAssertionID =
        IOPMAssertionID(kIOPMNullAssertionID)

    // MARK: - Logger

    private let logger = Logger(
        subsystem: "com.srimanachanta.stasis",
        category: "ChargeManager"
    )

    // MARK: - Init

    init(
        batteryService: BatteryService,
        nativeCoordinator: NativeChargeLimitCoordinator? = nil,
        startObserving: Bool = true,
        sleepAssertionHandler: ((Bool) -> Void)? = nil,
        record: @escaping (String, String) -> Void = { ControlDiagnostics.shared.record($0, $1) }
    ) {
        self.batteryService = batteryService
        self.sleepAssertionHandler = sleepAssertionHandler
        self.record = record

        self.nativeChargeLimitCoordinator =
            nativeCoordinator ?? NativeChargeLimitCoordinator(
                batteryService: batteryService
            )

        self.nativeChargeLimitCoordinator.setSuspended(
            !batteryService.hasObservedIOKitState ||
            (Defaults[.manageCharging] && !batteryService.controlState.adapterConnected)
        )

        guard startObserving else { return }
        startObservingMetrics()
        startObservingSettings()
        startObservingSleepWake()
        startCalibrationTimer()
    }

    // MARK: - Observe Battery

    private func startObservingMetrics() {

        metricsObservation = Task { [weak self] in

            guard let self else {
                return
            }

            while !Task.isCancelled {

                self.evaluate(
                    controlState:
                        self.batteryService.controlState
                )

                await withCheckedContinuation { continuation in

                    withObservationTracking {

                        _ =
                            self.batteryService.controlState

                        _ =
                            self.batteryService.deviceCapabilities
                        _ = self.batteryService.hasObservedIOKitState

                    } onChange: {

                        Task { @MainActor in
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Observe Settings

    private func startObservingSettings() {

        settingsObservation = Task { [weak self] in

            for await _ in Defaults.updates(
                [
                    .manageCharging,
                    .sailingMode,
                    .automaticDischarge,
                    .disableSleepUntilChargeLimit,
                    .enableHeatProtectionMode,
                    .manageMagSafeLED,
                    .useHardwarePercentage,
                    .chargeLimit,
                    .sailingModeLimit,
                    .heatProtectionLimit,
                    .automaticMonthlyCalibration,
                ],
                initial: false
            ) {
                guard let self else {
                    return
                }

                self.evaluate(
                    controlState:
                        self.batteryService.controlState
                )
            }
        }
    }

    // MARK: - Sleep / Wake

    private func startObservingSleepWake() {

        let center =
            NSWorkspace.shared.notificationCenter

        sleepObservationTask = Task { [weak self] in

            for await _ in center.notifications(
                named: NSWorkspace.willSleepNotification
            ) {
                guard let self else {
                    return
                }

                self.handleWillSleep()
            }
        }

        wakeObservationTask = Task { [weak self] in

            for await _ in center.notifications(
                named: NSWorkspace.didWakeNotification
            ) {
                guard let self else {
                    return
                }

                self.handleDidWake()
            }
        }
    }

    func handleWillSleep() {
        record("POWER_EVENT", "will sleep; restoring external power")
        sleepPauseActive = true
        nativeChargeLimitCoordinator.setSuspended(true)
        updateSleepAssertion(shouldPreventSleep: false)

        guard
            Defaults[.manageCharging],
            batteryService.controlState.adapterConnected
        else {
            return
        }

        logger.info(
            "System preparing to sleep"
        )

        /*
         真正进入 Sleep 前：

         Charging OFF
         Adapter ON

         防止机器睡着以后继续突破 Charge Limit。
         */
        invalidateAppliedControlState()

        evaluate(
            controlState:
                batteryService.controlState
        )
    }

    func handleDidWake() {
        record("POWER_EVENT", "did wake; refreshing power source before resuming native control")

        logger.info(
            "System woke from sleep"
        )

        sleepPauseActive = false

        invalidateAppliedControlState()

        batteryService.scheduleSinglePoll(
            delay: .milliseconds(100)
        )

        Task { [weak self] in

            try? await Task.sleep(
                for: .milliseconds(350)
            )

            guard
                let self,
                !Task.isCancelled
            else {
                return
            }

            self.evaluate(
                controlState:
                    self.batteryService.controlState
            )
        }
    }

    // MARK: - Main Policy

    func evaluate(
        controlState: BatteryControlState
    ) {

        guard batteryService.hasObservedIOKitState else { return }

        // A physical cable can remain connected during CHIE discharge. Use the
        // control state's adapter presence, not the battery's power-flow flag.
        // An explicit management-off request may still disable MCL while awake.
        nativeChargeLimitCoordinator.setSuspended(
            sleepPauseActive || (Defaults[.manageCharging] && !controlState.adapterConnected)
        )

        if chargeLimitOverrideActive {
            if Defaults[.topUpLastAdapterConnected] && !controlState.adapterConnected {
                chargeLimitOverrideActive = false
                Defaults[.topUpSessionActive] = false
            } else {
                Defaults[.topUpLastAdapterConnected] = controlState.adapterConnected
            }
        }

        let capabilities = batteryService.deviceCapabilities
        let capabilitiesMask =
            (capabilities.chargingControl ? 1 : 0) |
            (capabilities.adapterControl ? 2 : 0) |
            (capabilities.magsafeLEDControl ? 4 : 0)
        if lastCapabilitiesMask != capabilitiesMask {
            lastCapabilitiesMask = capabilitiesMask
            controlRevision &+= 1
            blockedControlRevision = nil
            runtimeChargingControlUnsupported = false
            invalidateAppliedControlState()
        }

        let adapterChanged =
            lastAdapterConnected
            != controlState.adapterConnected

        if adapterChanged {

            if lastAdapterConnected == true,
               !controlState.adapterConnected {
                Defaults[.topUpSessionActive] = false
                chargeLimitOverrideActive = false
            }

            lastAdapterConnected =
                controlState.adapterConnected

            invalidateAppliedControlState()

            logger.info(
                "Adapter changed: \(controlState.adapterConnected)"
            )
        }

        // MARK: Disabled / Unplugged

        // 用户真正关闭“充电管理”
        //
        // → 退出 Top Up
        // → 停止手动放电
        // → 停止自动放电过程
        // → 解除 macOS Native MCL
        //
        // 最终应该恢复成系统默认充电行为。

        guard Defaults[.manageCharging] else {

            Defaults[.calibrationPhase] = .idle
            Defaults[.calibrationHoldStartedAt] = nil

            chargeLimitOverrideActive =
                false
            Defaults[.topUpSessionActive] = false

            forceDischargeActive =
                false

            automaticDischargeActive =
                false

            if nativeChargeLimitAvailable {

                nativeChargeLimitCoordinator
                    .request(
                        enabled: false,
                        limit: nil
                    )
            }

            resetToDefaults()

            return
        }

        // 拔掉充电器：
        //
        // 这不是“关闭充电管理”。
        //
        // 普通 75% 上限仍然需要保存，
        // 这样下次重新插电以后
        // 仍然继续按照 75% 工作。
        //
        // Top Up 则在第一次拔电时结束：
        //
        // 75%
        // ↓
        // Top Up = 100%
        // ↓
        // 拔电
        // ↓
        // Top Up 结束
        // ↓
        // 恢复保存的普通上限 75%

        guard controlState.adapterConnected else {

            forceDischargeActive =
                false

            automaticDischargeActive =
                false

            if nativeChargeLimitAvailable {

                nativeChargeLimitCoordinator
                    .request(
                        enabled: true,

                        limit:
                            Defaults[
                                .chargeLimit
                            ]
                    )
            }

            resetToDefaults()

            return
        }


        // MARK: Current Target

        let batteryPercentage =
            selectedBatteryPercentage(
                controlState
            )

        let automaticDischarge =
            Defaults[
                .automaticDischarge
            ]

        let policyPlan = ChargePolicy.plan(
            percentage: batteryPercentage,
            normalLimit: Defaults[.chargeLimit],
            topUpActive: chargeLimitOverrideActive,
            adapterConnected: controlState.adapterConnected,
            automaticDischargeEnabled: automaticDischarge,
            chargingGateSupported: batteryService.deviceCapabilities.chargingControl,
            forceDischargeSupported: batteryService.deviceCapabilities.adapterControl
        )
        let chargeLimit = chargeLimitOverrideActive ? 100 : Defaults[.chargeLimit]



        // Native MCL 已经能够真正 Hold 在目标电量。
        //
        // 因此在支持 Native MCL 的机器上，
        // 不再启用旧 Sailing 循环：
        //
        // 75 → 74 → 再充到 75
        //
        // Native 设备直接交给 powerd
        // 长时间保持目标即可。
        let sailingModeActive =
            Defaults[.sailingMode]
            && !nativeChargeLimitAvailable

        // MARK: Native Manual Charge Limit

        // Native MCL 是这台 M4 Pro
        // 真正负责“停在目标电量”的后端。
        //
        // 普通情况：
        //
        // chargeLimit = 75
        // → 系统真正 Hold 在 75
        //
        // 用户改成 80：
        //
        // chargeLimit = 80
        // → 系统继续充到 80
        //
        // Top Up：
        //
        // effectiveChargeLimit = 100
        // → 系统充到并保持 100
        //
        // Calibration 后面会单独接自己的
        // 100% / return-to-limit 状态，
        // 所以校准运行时这里暂时不覆盖它。

        if nativeChargeLimitAvailable,
           !calibrationActive
        {
            nativeChargeLimitCoordinator
                .request(
                    enabled: true,
                    limit: forceDischargeActive ? chargeLimit : policyPlan.nativeLimit
                )
        }

        // MARK: Target Changed

        let targetChanged =
            lastRequestedLimit
            != chargeLimit

        let percentageSourceChanged = lastUseHardwarePercentage != Defaults[.useHardwarePercentage]
        lastUseHardwarePercentage = Defaults[.useHardwarePercentage]
        if targetChanged || percentageSourceChanged || lastManageChargingEnabled != true {

            if targetChanged {
                if automaticDischarge,
                   let previousLimit = lastRequestedLimit,
                   previousLimit > chargeLimit
                {
                    loweredTargetGuardLimit = chargeLimit
                    loweredTargetGuardUntil = Date().addingTimeInterval(
                        loweredTargetGuardDuration
                    )

                    record(
                        "OVERSHOOT_GUARD",
                        "armed previous=\(previousLimit) target=\(chargeLimit) battery=\(batteryPercentage)"
                    )
                } else {
                    loweredTargetGuardLimit = nil
                    loweredTargetGuardUntil = nil
                }
            }

            controlRevision &+= 1
            blockedControlRevision = nil
            controlRetryTask?.cancel()
            controlRetryTask = nil
            record("TARGET", "revision=\(controlRevision) target=\(chargeLimit) battery=\(batteryPercentage)")

            logger.info(
                "Charge limit changed: \(chargeLimit)%"
            )

            /*
             用户主动改变目标时重新判断：

             当前电量 > 新目标
             + Automatic Discharge 开启
             -> 主动放回新目标。
             */
            automaticDischargeActive = policyPlan.shouldDischarge

            hasReachedChargeLimit =
                batteryPercentage
                    == chargeLimit
        }

        lastRequestedLimit =
            chargeLimit

        // MARK: Automatic Discharge Setting Changed

        if lastAutomaticDischargeEnabled
            != automaticDischarge
        {
            if automaticDischarge {

                automaticDischargeActive = policyPlan.shouldDischarge

            } else {

                automaticDischargeActive =
                    false
            }

            lastAutomaticDischargeEnabled =
                automaticDischarge
        }

        // 插着高于目标的电量重新连接电源
        if adapterChanged,
           controlState.adapterConnected
        {
            automaticDischargeActive = policyPlan.shouldDischarge
        }

        // 一旦到目标，Automatic Discharge 必须结束。
        if batteryPercentage
            <= chargeLimit
        {
            automaticDischargeActive =
                false
        }

        // MARK: Lowered Target Overshoot Guard

        if let guardedLimit = loweredTargetGuardLimit {

            let guardExpired =
                loweredTargetGuardUntil
                    .map { Date() >= $0 }
                ?? true

            if guardExpired || guardedLimit != chargeLimit {

                loweredTargetGuardLimit = nil
                loweredTargetGuardUntil = nil

            } else if
                automaticDischarge,
                !forceDischargeActive,
                !chargeLimitOverrideActive,
                !calibrationActive,
                batteryPercentage > chargeLimit,
                !automaticDischargeActive
            {
                automaticDischargeActive = true

                record(
                    "OVERSHOOT_GUARD",
                    "rearmed target=\(chargeLimit) battery=\(batteryPercentage)"
                )
            }
        }

        // MARK: Sleep Safety

        // Catch continued charging even after the short target-change window.
        // Merely being above the target is not enough: require fresh positive
        // battery power, automatic discharge permission and an awake, connected Mac.
        if shouldProtectFromContinuedOvercharge && !automaticDischargeActive {
            automaticDischargeActive = true
            record("OVERCHARGE_GUARD", "continued charging above target=\(chargeLimit) battery=\(batteryPercentage)")
        }

        if sleepPauseActive {

            queueControlState(
                charging: false,
                adapter: true,
                led:
                    ledManagementEnabled
                    ? (
                        batteryPercentage
                            >= chargeLimit
                        ? .green
                        : .orange
                    )
                    : .reset
            )

            updateSleepAssertion(
                shouldPreventSleep: false
            )

            return
        }

        // MARK: Monthly Calibration

        triggerMonthlyCalibrationIfDue(
            adapterConnected:
                controlState.adapterConnected
        )

        // MARK: First Enable

        if lastManageChargingEnabled
            != true
        {
            lastManageChargingEnabled =
                true

            invalidateAppliedControlState()
        }

        // MARK: Calibration

        if calibrationActive {

            evaluateCalibration(
                batteryPercentage:
                    batteryPercentage
            )

            return
        }

        // MARK: Force Discharge Stop

        if forceDischargeActive,
           batteryPercentage
            <= chargeLimit
        {
            forceDischargeActive = false

            automaticDischargeActive = false

            invalidateAppliedControlState()

            logger.info(
                "Force discharge target reached"
            )
        }

        var desiredCharging = true
        var desiredAdapter = true

        var desiredLED:
            MagSafeLEDState =
                ledManagementEnabled
                ? .orange
                : .reset

        var reason:
            String?

        // MARK: Manual Force Discharge

        if forceDischargeActive {

            desiredCharging = false
            desiredAdapter = false

            desiredLED =
                ledManagementEnabled
                ? .blinkOrangeSlow
                : .reset

            reason =
                "Force Discharge"

        }

        // MARK: Automatic Discharge

        else if automaticDischargeActive,
                batteryPercentage > chargeLimit
        {
            desiredCharging = false
            desiredAdapter = false

            desiredLED =
                ledManagementEnabled
                ? .blinkOrangeSlow
                : .reset

            reason =
                "Discharging to \(chargeLimit)%"
        }

        // MARK: At / Above Limit

        else if batteryPercentage >= chargeLimit {

            /*
             这是你现在最需要的状态：

             Limit = 75
             Battery = 75

             Charging OFF
             Adapter ON

             电池不充、不主动放。
             */

            hasReachedChargeLimit = true
            automaticDischargeActive = false

            desiredCharging = false
            desiredAdapter = true

            desiredLED =
                ledManagementEnabled
                ? .green
                : .reset

            reason =
                "Charge limit reached: \(chargeLimit)%"
        }

        // MARK: Below Limit

        else {

            if sailingModeActive,
               !chargeLimitOverrideActive,
               hasReachedChargeLimit
            {
                let resumeAt =
                    chargeLimit
                    - Defaults[.sailingModeLimit]

                if batteryPercentage >= resumeAt {

                    // Sailing：
                    // 到达过上限以后允许自然下降，
                    // 不立即重新补电。
                    desiredCharging = false
                    desiredAdapter = true

                    desiredLED =
                        ledManagementEnabled
                        ? .green
                        : .reset

                    reason =
                        "Sailing Mode"

                } else {

                    hasReachedChargeLimit = false

                    desiredCharging = true
                    desiredAdapter = true

                    desiredLED =
                        ledManagementEnabled
                        ? .orange
                        : .reset

                    reason =
                        "Charging to \(chargeLimit)%"
                }

            } else {

                hasReachedChargeLimit = false

                desiredCharging = true
                desiredAdapter = true

                desiredLED =
                    ledManagementEnabled
                    ? .orange
                    : .reset

                reason =
                    "Charging to \(chargeLimit)%"
            }
        }

        // MARK: Heat Protection

        let heatProtectionActive =
            capabilities.chargingControl && !runtimeChargingControlUnsupported &&
            Defaults[.enableHeatProtectionMode]
            &&
            controlState.batteryTemperature
            >
            Double(
                Defaults[.heatProtectionLimit]
            )

        if heatProtectionActive {

            /*
             Heat Protection：
             停止给电池充电，
             但 Mac 仍然由 Adapter 供电。
             */
            desiredCharging = false
            desiredAdapter = true

            desiredLED =
                ledManagementEnabled
                ? .orange
                : .reset

            reason =
                "Heat Protection"
        }

        // MARK: Apply

        queueControlState(
            charging:
                desiredCharging,

            adapter:
                desiredAdapter,

            led:
                desiredLED
        )

        sendChargingStateNotification(
            charging:
                desiredCharging,

            reason:
                reason
        )

        // MARK: Sleep Prevention

        let chargingTowardTarget =
            desiredCharging
            &&
            batteryPercentage
                < chargeLimit

        let dischargingTowardTarget =
            !desiredAdapter
            &&
            !forceDischargeActive
            &&
            batteryPercentage
                > chargeLimit

        updateSleepAssertion(
            shouldPreventSleep:
                Defaults[
                    .disableSleepUntilChargeLimit
                ]
                &&
                !heatProtectionActive
                &&
                !forceDischargeActive
                &&
                (
                    chargingTowardTarget
                    ||
                    dischargingTowardTarget
                )
        )
    }

    // MARK: - Percentage

    private func selectedBatteryPercentage(
        _ controlState: BatteryControlState
    ) -> Int {

        Defaults[.useHardwarePercentage]
            ? controlState.hardwareBatteryPercentage
            : controlState.batteryPercentage
    }

    // MARK: - LED

    private var ledManagementEnabled:
        Bool
    {
        Defaults[.manageMagSafeLED]
        &&
        batteryService
            .deviceCapabilities
            .hasMagSafe
        &&
        batteryService
            .deviceCapabilities
            .magsafeLEDControl
    }

    // MARK: - Queue State

    private func queueControlState(
        charging: Bool,
        adapter: Bool,
        led: MagSafeLEDState
    ) {
        let controlChanged = desiredChargingCommand != charging || desiredAdapterCommand != adapter
        let ledChanged = desiredLEDCommand != led
        if controlChanged {
            controlRevision &+= 1
            blockedControlRevision = nil
            controlRetryTask?.cancel()
            controlRetryTask = nil
            record("PLAN", "revision=\(controlRevision) target=\(nativeLimitForCurrentPhase) charging=\(charging) externalPower=\(adapter) battery=\(selectedBatteryPercentage(batteryService.controlState))")
        }
        desiredChargingCommand = charging
        desiredAdapterCommand = adapter
        desiredLEDCommand = led
        startControlTaskIfNeeded()
        if ledChanged { startLEDTaskIfNeeded() }
    }

    private func startControlTaskIfNeeded() {
        guard !preparingForHelperRemoval,
              controlTask == nil, controlRetryTask == nil,
              blockedControlRevision != controlRevision,
              !controlStateIsSatisfied() else { return }

        controlTask = Task { [weak self] in
            guard let self else { return }
            let success = await self.flushControlCommands()
            self.controlTask = nil
            guard !Task.isCancelled else { return }
            if !success {
                self.scheduleControlRetry()
            } else if !self.controlStateIsSatisfied() {
                self.startControlTaskIfNeeded()
            }
        }
    }

    private func flushControlCommands() async -> Bool {
        while !Task.isCancelled {
            guard let charging = desiredChargingCommand,
                  let externalPower = desiredAdapterCommand else { return true }
            let capabilities = batteryService.deviceCapabilities
            let revision = controlRevision

            if !externalPower {
                guard capabilities.adapterControl else {
                    blockedControlRevision = revision
                    record("UNSUPPORTED", "force discharge is unavailable")
                    return false
                }
                if appliedAdapterCommand != false {
                    if nativeChargeLimitAvailable {
                        let ready = await nativeChargeLimitCoordinator.requestAndWait(
                            enabled: true, limit: nativeLimitForCurrentPhase,
                            timeout: shouldProtectFromContinuedOvercharge ? .seconds(2) : .seconds(5),
                            isCurrent: { [weak self] in self?.controlRevision == revision }
                        )
                        guard !Task.isCancelled else { return true }
                        guard revision == controlRevision else { continue }
                        if !ready {
                            guard shouldProtectFromContinuedOvercharge else { return false }
                            record("OVERCHARGE_GUARD", "native pending; stopping measured charging above target=\(nativeLimitForCurrentPhase)")
                        }
                    }
                    guard await performAdapterCommand(enabled: false) else { return false }
                    // A completed command changed hardware even if the user's plan changed
                    // while XPC was in flight. Forgetting it can suppress the next CHIE OFF.
                    appliedAdapterCommand = false
                    appliedChargingCommand = nil
                    guard revision == controlRevision else { continue }
                }
            } else {
                // Restoring external power never waits for a native-limit request.
                if capabilities.adapterControl, appliedAdapterCommand != true {
                    guard await performAdapterCommand(enabled: true) else { return false }
                    appliedAdapterCommand = true
                    guard revision == controlRevision else { continue }
                }
                if capabilities.chargingControl && !runtimeChargingControlUnsupported,
                   appliedChargingCommand != charging {
                    guard await performChargingCommand(enabled: charging) else { return false }
                    appliedChargingCommand = charging
                    guard revision == controlRevision else { continue }
                }
            }
            if controlStateIsSatisfied() { return true }
        }
        return true
    }

    private var shouldProtectFromContinuedOvercharge: Bool {
        guard !sleepPauseActive, !preparingForHelperRemoval,
              Defaults[.manageCharging], Defaults[.automaticDischarge],
              !chargeLimitOverrideActive, !calibrationActive, !forceDischargeActive,
              batteryService.controlState.adapterConnected,
              batteryService.deviceCapabilities.adapterControl,
              selectedBatteryPercentage(batteryService.controlState) > effectiveChargeLimit,
              let sampledAt = batteryService.powerSampleDate else { return false }
        let age = Date().timeIntervalSince(sampledAt)
        let metrics = batteryService.metrics
        return (0...8).contains(age) && metrics.batteryPower.isFinite &&
            metrics.batteryPower > 0.5 && metrics.batteryCurrent.isFinite && metrics.batteryCurrent > 0.05
    }

    private func controlStateIsSatisfied() -> Bool {
        guard let charging = desiredChargingCommand,
              let externalPower = desiredAdapterCommand else { return true }
        let capabilities = batteryService.deviceCapabilities
        let gateSatisfied = !externalPower || !capabilities.chargingControl ||
            runtimeChargingControlUnsupported || appliedChargingCommand == charging
        let adapterSatisfied = capabilities.adapterControl
            ? appliedAdapterCommand == externalPower : externalPower
        return gateSatisfied && adapterSatisfied
    }

    private func startLEDTaskIfNeeded() {
        guard ledControlTask == nil,
              batteryService.deviceCapabilities.hasMagSafe,
              batteryService.deviceCapabilities.magsafeLEDControl else { return }
        // Cosmetic hardware writes must not delay restoring external power.
        ledControlTask = Task { [weak self] in
            guard let self else { return }
            defer { self.ledControlTask = nil }
            while !Task.isCancelled,
                  let desired = self.desiredLEDCommand,
                  desired != self.appliedLEDCommand {
                guard await self.performLEDCommand(state: desired) else { return }
                self.appliedLEDCommand = desired
            }
        }
    }

    // MARK: - Retry

    private func scheduleControlRetry() {

        guard controlRetryTask == nil,
              blockedControlRevision != controlRevision,
              !preparingForHelperRemoval else { return }

        controlRetryTask = Task { [weak self] in

            try? await Task.sleep(
                for: .seconds(2)
            )

            guard
                let self,
                !Task.isCancelled
            else {
                return
            }

            self.controlRetryTask = nil

            self.startControlTaskIfNeeded()
        }
    }

    // MARK: - Execute Charging

    private func performChargingCommand(
        enabled: Bool
    ) async -> Bool {

        logger.info(
            "Setting charging: \(enabled)"
        )
        // A transport failure cannot prove that the hardware write did not run.
        appliedChargingCommand = nil

        do {

            try await batteryService
                .manageBatteryCharging(
                    enabled: enabled
                )

            logger.info(
                "Charging command succeeded: \(enabled)"
            )

            batteryService.scheduleTransitionPolls()

            return true

        } catch {

            if error.localizedDescription.localizedCaseInsensitiveContains("not supported") {
                runtimeChargingControlUnsupported = true
                logger.warning("Charging Gate unsupported; continuing with native limit and CHIE")
                return true
            }

            logger.error(
                """
                CHARGING COMMAND FAILED \
                enabled=\(enabled) \
                error=\(error.localizedDescription)
                """
            )

            return false
        }
    }

    // MARK: - Execute Adapter

    private func performAdapterCommand(
        enabled: Bool
    ) async -> Bool {

        record("CHIE_SEND", "forceDischarge=\(!enabled) revision=\(controlRevision)")
        logger.info("Setting adapter: \(enabled)")
        // On timeout/invalidation, the helper may have written CHIE already.
        // Keep the cache unknown so a newer plan still sends its corrective OFF.
        appliedAdapterCommand = nil

        do {

            try await batteryService
                .manageExternalPower(
                    enabled: enabled
                )

            record("CHIE_ACK", "forceDischarge=\(!enabled)")
            batteryService.scheduleTransitionPolls()

            return true

        } catch {
            record("CHIE_ERROR", error.localizedDescription)

            if error.localizedDescription.localizedCaseInsensitiveContains("not supported") {
                blockedControlRevision = controlRevision
            }

            logger.error(
                """
                ADAPTER COMMAND FAILED \
                enabled=\(enabled) \
                error=\(error.localizedDescription)
                """
            )

            return false
        }
    }

    // MARK: - Execute LED

    private func performLEDCommand(
        state: MagSafeLEDState
    ) async -> Bool {

        do {

            try await batteryService
                .manageMagsafeLED(
                    target: state
                )

            return true

        } catch {
            record("LED_ERROR", error.localizedDescription)

            logger.error(
                """
                LED COMMAND FAILED: \
                \(error.localizedDescription)
                """
            )

            return false
        }
    }

    // MARK: - Cache

    private func invalidateAppliedControlState() {

        appliedChargingCommand = nil
        appliedAdapterCommand = nil
        appliedLEDCommand = nil
    }

    // MARK: - Reset

    private func resetToDefaults() {

        hasReachedChargeLimit = false
        automaticDischargeActive = false

        loweredTargetGuardLimit = nil
        loweredTargetGuardUntil = nil

        lastManageChargingEnabled = false

        updateSleepAssertion(
            shouldPreventSleep: false
        )

        /*
         即使 manageCharging 已经关闭，
         这里也必须真正尝试恢复：

         Charging ON
         Adapter ON
         */
        queueControlState(
            charging: true,
            adapter: true,
            led: .reset
        )
    }

    // MARK: - Sleep Assertion

    private func updateSleepAssertion(
        shouldPreventSleep: Bool
    ) {
        if let sleepAssertionHandler {
            sleepAssertionHandler(shouldPreventSleep)
            return
        }

        let active =
            sleepAssertionID
            != IOPMAssertionID(
                kIOPMNullAssertionID
            )

        if shouldPreventSleep,
           !active
        {
            let result =
                IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventSystemSleep
                        as CFString,

                    IOPMAssertionLevel(
                        kIOPMAssertionLevelOn
                    ),

                    "Stasis: Reaching charge limit"
                        as CFString,

                    &sleepAssertionID
                )

            if result
                == kIOReturnSuccess
            {
                logger.info(
                    "PreventSystemSleep enabled"
                )
            }

        } else if
            !shouldPreventSleep,
            active
        {
            IOPMAssertionRelease(
                sleepAssertionID
            )

            sleepAssertionID =
                IOPMAssertionID(
                    kIOPMNullAssertionID
                )
        }
    }

    // MARK: - Notifications

    private func sendChargingStateNotification(
        charging: Bool,
        reason: String?
    ) {

        guard
            charging
            != lastNotifiedChargingState
        else {
            return
        }

        lastNotifiedChargingState =
            charging

        guard
            !Defaults[.disableNotifications],
            Defaults[
                .showChargingStatusChangedNotification
            ]
        else {
            return
        }

        let content =
            UNMutableNotificationContent()

        content.title =
            charging
            ? String(
                localized:
                    "Charging Resumed"
            )
            : String(
                localized:
                    "Charging Paused"
            )

        if let reason {
            content.body = reason
        }

        content.sound = .default

        let request =
            UNNotificationRequest(
                identifier:
                    "chargingStateChanged",

                content:
                    content,

                trigger:
                    nil
            )

        UNUserNotificationCenter
            .current()
            .add(request)
    }

    // MARK: - Top Up

    func toggleChargeLimitOverride() {

        forceDischargeActive = false
        automaticDischargeActive = false

        chargeLimitOverrideActive.toggle()
        Defaults[.topUpSessionActive] = chargeLimitOverrideActive
        Defaults[.topUpLastAdapterConnected] = batteryService.controlState.adapterConnected

        hasReachedChargeLimit = false

        invalidateAppliedControlState()

        evaluate(
            controlState:
                batteryService.controlState
        )
    }

    // MARK: - Force Discharge

    func toggleForceDischarge() {

        if !forceDischargeActive {

            chargeLimitOverrideActive = false
            Defaults[.topUpSessionActive] = false

            automaticDischargeActive = false
        }

        forceDischargeActive.toggle()

        invalidateAppliedControlState()

        evaluate(
            controlState:
                batteryService.controlState
        )
    }

    // MARK: - Calibration

    func startCalibration() {

        guard
            Defaults[.manageCharging],
            batteryService.deviceCapabilities.adapterControl,
            batteryService.controlState.adapterConnected
        else {
            return
        }

        chargeLimitOverrideActive = false
        Defaults[.topUpSessionActive] = false
        forceDischargeActive = false
        automaticDischargeActive = false

        invalidateAppliedControlState()

        Defaults[
            .calibrationOriginalLimit
        ] =
            Defaults[.chargeLimit]

        Defaults[
            .calibrationHoldStartedAt
        ] =
            nil

        Defaults[
            .calibrationPhase
        ] =
            .chargingToFull
        Defaults[.lastCalibrationAttemptDate] = Date()

        evaluate(
            controlState:
                batteryService.controlState
        )
    }

    func cancelCalibration() {

        Defaults[
            .calibrationPhase
        ] =
            .idle

        Defaults[
            .calibrationHoldStartedAt
        ] =
            nil

        invalidateAppliedControlState()

        updateSleepAssertion(
            shouldPreventSleep: false
        )

        evaluate(
            controlState:
                batteryService.controlState
        )
    }

    private func startCalibrationTimer() {

        calibrationTimerTask =
            Task { [weak self] in

                while !Task.isCancelled {

                    try? await Task.sleep(
                        for: .seconds(30)
                    )

                    guard
                        let self,
                        !Task.isCancelled
                    else {
                        return
                    }

                    self.evaluate(
                        controlState:
                            self.batteryService.controlState
                    )
                }
            }
    }

    private func triggerMonthlyCalibrationIfDue(
        adapterConnected: Bool
    ) {

        guard
            Defaults[
                .automaticMonthlyCalibration
            ],
            Defaults[
                .manageCharging
            ],
            Defaults[
                .calibrationPhase
            ] == .idle,
            !chargeLimitOverrideActive,
            !forceDischargeActive,
            batteryService.deviceCapabilities.adapterControl,
            adapterConnected
        else {
            return
        }

        // A cancelled monthly attempt must not restart on the very next poll.
        // Keep attempts separate from successful completion dates.
        guard
            let lastDate = [Defaults[.lastCalibrationDate], Defaults[.lastCalibrationAttemptDate]]
                .compactMap({ $0 }).max()
        else {

            Defaults[
                .lastCalibrationDate
            ] =
                Date()

            return
        }

        guard
            let nextDate =
                Calendar.current.date(
                    byAdding: .month,
                    value: 1,
                    to: lastDate
                ),
            Date() >= nextDate
        else {
            return
        }

        startCalibration()
    }

    private func evaluateCalibration(
        batteryPercentage: Int
    ) {

        var desiredCharging = true
        var desiredAdapter = true

        var desiredLED:
            MagSafeLEDState =
                ledManagementEnabled
                ? .orange
                : .reset

        var completed = false

        switch Defaults[
            .calibrationPhase
        ] {

        case .idle:

            return

        case .chargingToFull:

            desiredCharging = true
            desiredAdapter = true

            if batteryPercentage >= 100 {

                Defaults[
                    .calibrationPhase
                ] =
                    .dischargingToTen

                desiredCharging = false
                desiredAdapter = false

                desiredLED =
                    ledManagementEnabled
                    ? .blinkOrangeSlow
                    : .reset
            }

        case .dischargingToTen:

            desiredCharging = false
            desiredAdapter = false

            desiredLED =
                ledManagementEnabled
                ? .blinkOrangeSlow
                : .reset

            if batteryPercentage <= 10 {

                Defaults[
                    .calibrationPhase
                ] =
                    .chargingToFullAgain

                desiredCharging = true
                desiredAdapter = true

                desiredLED =
                    ledManagementEnabled
                    ? .orange
                    : .reset
            }

        case .chargingToFullAgain:

            desiredCharging = true
            desiredAdapter = true

            if batteryPercentage >= 100 {

                Defaults[
                    .calibrationPhase
                ] =
                    .holdingAtFull

                Defaults[
                    .calibrationHoldStartedAt
                ] =
                    Date()

                desiredCharging = false
                desiredAdapter = true
            }

        case .holdingAtFull:

            desiredCharging = false
            desiredAdapter = true

            if let startedAt =
                Defaults[
                    .calibrationHoldStartedAt
                ],
               Date().timeIntervalSince(
                    startedAt
               ) >= 60 * 60
            {
                Defaults[
                    .calibrationPhase
                ] =
                    .returningToLimit

                desiredCharging = false
                desiredAdapter = false

                desiredLED =
                    ledManagementEnabled
                    ? .blinkOrangeSlow
                    : .reset
            }

        case .returningToLimit:

            desiredCharging = false
            desiredAdapter = false

            desiredLED =
                ledManagementEnabled
                ? .blinkOrangeSlow
                : .reset

            let originalLimit =
                Defaults[
                    .calibrationOriginalLimit
                ]

            if batteryPercentage
                <= originalLimit
            {
                Defaults[
                    .calibrationPhase
                ] =
                    .idle

                Defaults[
                    .calibrationHoldStartedAt
                ] =
                    nil

                Defaults[
                    .lastCalibrationDate
                ] =
                    Date()

                desiredCharging = false
                desiredAdapter = true

                desiredLED =
                    ledManagementEnabled
                    ? .green
                    : .reset

                hasReachedChargeLimit = true

                completed = true
            }
        }

        if nativeChargeLimitAvailable {
            nativeChargeLimitCoordinator.request(
                enabled: true,
                limit: nativeLimitForCurrentPhase
            )
        }

        queueControlState(
            charging:
                desiredCharging,

            adapter:
                desiredAdapter,

            led:
                desiredLED
        )

        updateSleepAssertion(
            shouldPreventSleep:
                !completed
        )
    }

    // MARK: - Stop

    func prepareForHelperRemoval() async throws {
        preparingForHelperRemoval = true
        defer { preparingForHelperRemoval = false }
        controlRevision &+= 1
        let previousTask = controlTask
        previousTask?.cancel()
        await previousTask?.value
        controlTask = nil
        controlRetryTask?.cancel()
        controlRetryTask = nil

        do {
            try await batteryService.manageExternalPower(enabled: true)
            appliedAdapterCommand = true
        } catch {
            if !error.localizedDescription.localizedCaseInsensitiveContains("not supported") ||
                batteryService.deviceCapabilities.adapterControl || appliedAdapterCommand == false {
                throw error
            }
            // The helper itself confirmed this device has no CHIE backend.
        }
        if batteryService.deviceCapabilities.chargingControl {
            do {
                try await batteryService.manageBatteryCharging(enabled: true)
                appliedChargingCommand = true
            } catch {
                if !error.localizedDescription.localizedCaseInsensitiveContains("not supported") {
                    throw error
                }
            }
        }
        Defaults[.manageCharging] = false
        Defaults[.topUpSessionActive] = false
        chargeLimitOverrideActive = false
        evaluate(controlState: batteryService.controlState)
    }

    func stop() {
        ledControlTask?.cancel()
        ledControlTask = nil
        nativeChargeLimitCoordinator.stop()

        metricsObservation?.cancel()
        metricsObservation = nil

        settingsObservation?.cancel()
        settingsObservation = nil

        calibrationTimerTask?.cancel()
        calibrationTimerTask = nil

        sleepObservationTask?.cancel()
        sleepObservationTask = nil

        wakeObservationTask?.cancel()
        wakeObservationTask = nil

        controlTask?.cancel()
        controlTask = nil

        controlRetryTask?.cancel()
        controlRetryTask = nil

        updateSleepAssertion(
            shouldPreventSleep: false
        )
    }
}
