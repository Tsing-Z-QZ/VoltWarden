import Foundation
import Observation
import os.log
import smc_power

enum PowerPollingCadence {
    static func interval(fast: Bool, adapterConnected: Bool,
                         isCharging: Bool, batteryPower: Double) -> Duration {
        if fast { return .milliseconds(500) }
        // Keep the existing control-response cadence while charge is moving.
        if adapterConnected && (isCharging || batteryPower > 0.5 || batteryPower < -2) {
            return .seconds(2)
        }
        // IOKit still reports power-source changes immediately. A held or
        // unplugged battery does not need an SMC request every two seconds.
        return .seconds(10)
    }
}

nonisolated enum XPCError: LocalizedError {
    case helperUnavailable
    case commandFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "XPC helper is unavailable"

        case .commandFailed(let message):
            "Command failed: \(message)"
        case .timedOut:
            "XPC helper request timed out"
        }
    }
}

nonisolated final class XPCCommandCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// A single completion gate handles replies, transport errors, and deadline races.
@MainActor
func performXPCRequest<Value: Sendable>(
    timeout: Duration = .seconds(8),
    _ send: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        let completion = XPCCommandCompletion<Value>(continuation)
        Task.detached {
            try? await Task.sleep(for: timeout)
            completion.finish(.failure(XPCError.timedOut))
        }
        send { completion.finish($0) }
    }
}

@MainActor
@Observable
class BatteryService {

    private func performChargingHelperCommand(
        _ send: (ChargingHelperProtocol, @escaping @Sendable (Bool, String?) -> Void) -> Void
    ) async throws {
        let _: Void = try await performXPCRequest { finish in
            guard let helper = ChargingHelperManager.shared.getHelper(
                errorHandler: { finish(.failure($0)) }
            ) else {
                finish(.failure(XPCError.helperUnavailable))
                return
            }
            send(helper) { success, message in
                finish(success ? .success(()) :
                    .failure(XPCError.commandFailed(message ?? "Unknown error")))
            }
        }
    }

    var metrics = BatteryMetrics()
    private(set) var powerSampleDate: Date?

    var adapterMetrics =
        AdapterMetrics()

    private(set) var controlState =
        BatteryControlState()
    private(set) var hasObservedIOKitState = false
    private var capabilitiesLoaded = false
    private var loadingCapabilities = false
    private var lastSampleLog = Date.distantPast
    private var lastRealtimeBatterySample = Date.distantPast

    private(set) var deviceCapabilities =
        DeviceCapabilities(
            chargingControl: false,
            adapterControl: false,
            hasMagSafe: false,
            magsafeLEDControl: false
        )

    // MARK: - Services

    // 普通 SMC Reader Helper
    //
    // 负责：
    //
    // 电池电压
    // 电池电流
    // 电池功率
    // 适配器功率
    // SMC 硬件能力
    private let xpcManager =
        SMCReaderConnection(
            serviceName:
                "com.srimanachanta.stasis.helper"
        )

    // IOKit 负责系统层面的电池状态。
    private let ioKitService =
        IOKitService()

    // MARK: - Tasks

    private var ioKitMonitorTask:
        Task<Void, Never>?

    private var smcPollTask:
        Task<Void, Never>?

    private var nextPollSleepTask: Task<Void, Never>?

    private var delayedPollTask:
        Task<Void, Never>?

    // MARK: - Polling State

    // 菜单打开时提高轮询速度。
    private var isFastPolling =
        false

    // 用这两个标志区分：
    //
    // 当前 metrics 里的实时数据
    // 到底有没有经过 SMC 更新。
    private var hasRealtimeBatteryReading =
        false

    private var hasRealtimeAdapterReading =
        false

    // MARK: - Logger

    private let logger =
        Logger(
            subsystem:
                "com.srimanachanta.stasis",

            category:
                "BatteryService"
        )

    // MARK: - Init

    init() {

        logger.info(
            "BatteryService initialized"
        )

        // 建立普通 SMC Reader XPC 连接。
        xpcManager.connect()

        // 开始监听 IOKit。
        startIOKitMonitoring()

        // 开始真正的循环轮询。
        startContinuousPolling()
    }

    #if DEBUG
    // Tests exercise ChargeManager itself without connecting to either helper.
    init(testState: BatteryControlState, capabilities: DeviceCapabilities) {
        controlState = testState
        deviceCapabilities = capabilities
        hasObservedIOKitState = true
    }

    func setTestState(_ state: BatteryControlState) {
        controlState = state
    }

    func setTestPowerSample(watts: Double, current: Double, date: Date = Date()) {
        metrics.batteryPower = watts
        metrics.batteryCurrent = current
        powerSampleDate = date
    }
    #endif

    // MARK: - Device Capabilities

    func loadCapabilities() async {
        guard !loadingCapabilities else { return }
        loadingCapabilities = true
        defer { loadingCapabilities = false }
        do {
            deviceCapabilities = try await performXPCRequest(timeout: .seconds(3)) { finish in
                guard let helper = xpcManager.getHelper(errorHandler: { finish(.failure($0)) }) else {
                    finish(.failure(XPCError.helperUnavailable))
                    return
                }
                helper.getCapabilities { charging, adapter, magSafe, led in
                    finish(.success(DeviceCapabilities(
                        chargingControl: charging, adapterControl: adapter,
                        hasMagSafe: magSafe, magsafeLEDControl: led
                    )))
                }
            }
            capabilitiesLoaded = true
            ControlDiagnostics.shared.record("CAPABILITIES", "gate=\(deviceCapabilities.chargingControl) forceDischarge=\(deviceCapabilities.adapterControl)")
        } catch {
            ControlDiagnostics.shared.record("CAPABILITIES_ERROR", error.localizedDescription)
        }
    }

    // MARK: - IOKit Monitoring

    private func startIOKitMonitoring() {

        logger.info(
            """
            Starting IOKit monitoring \
            in main app
            """
        )

        ioKitMonitorTask =
            Task {

                for await (
                    newBatteryMetrics,
                    newAdapterMetrics
                )
                in self
                    .ioKitService
                    .metricsStream()
                {
                    guard
                        !Task.isCancelled
                    else {
                        break
                    }

                    self.handleIOKitUpdate(
                        newBatteryMetrics,

                        adapterUpdate:
                            newAdapterMetrics
                    )
                }
            }
    }

    // MARK: - Polling Speed

    func enableFastPolling() {

        isFastPolling =
            true
        nextPollSleepTask?.cancel()

        logger.info(
            "Enabling fast SMC polling"
        )
    }

    func disableFastPolling() {

        isFastPolling =
            false
        nextPollSleepTask?.cancel()

        logger.info(
            "Disabling fast SMC polling"
        )
    }

    // MARK: - Continuous Polling

    private func startContinuousPolling() {

        guard
            smcPollTask == nil
        else {
            return
        }

        logger.info(
            """
            Starting continuous \
            battery polling
            """
        )

        smcPollTask =
            Task {

                while
                    !Task.isCancelled
                {

                    // ① 先刷新 IOKit 状态。

                    self
                        .ioKitService
                        .refreshMetrics()

                    // ② 再真正读取一次
                    // SMC 实时数据。

                    await self
                        .pollSMCOnce()

                    let interval = PowerPollingCadence.interval(
                        fast: self.isFastPolling,
                        adapterConnected: self.controlState.adapterConnected,
                        isCharging: self.metrics.isCharging,
                        batteryPower: self.metrics.batteryPower
                    )

                    let sleepTask = Task<Void, Never> {
                        _ = try? await Task.sleep(for: interval)
                    }
                    self.nextPollSleepTask = sleepTask
                    await sleepTask.value
                    self.nextPollSleepTask = nil

                    guard
                        !Task.isCancelled
                    else {
                        break
                    }
                }
            }
    }

    // 在执行一次充电控制后调用。
    //
    // 不仅刷新 IOKit，
    // 同时马上重新读取 SMC。
    func scheduleSinglePoll(
        delay:
            Duration =
                .milliseconds(150)
    ) {
        delayedPollTask?
            .cancel()

        delayedPollTask =
            Task {

                try?
                    await Task.sleep(
                        for:
                            delay
                    )

                guard
                    !Task.isCancelled
                else {
                    return
                }

                self
                    .ioKitService
                    .refreshMetrics()

                await self
                    .pollSMCOnce()
            }
    }

    /// Hardware current can take a little longer to reverse after a control
    /// acknowledgement. Sample frequently for a short bounded window so the
    /// displayed real state catches up without permanently increasing helper
    /// traffic or inventing a charging/discharging state.
    func scheduleTransitionPolls() {
        delayedPollTask?.cancel()

        delayedPollTask = Task {
            for delay in [100, 250, 450, 700, 1_000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }

                ioKitService.refreshMetrics()
                await pollSMCOnce()
            }
        }
    }

    // MARK: - SMC Reader

    private func fetchSMCBatteryData() async -> SMCBatteryReading? {
        try? await performXPCRequest(timeout: .seconds(3)) { finish in
            guard let helper = xpcManager.getHelper(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.helperUnavailable))
                return
            }
            helper.readBatteryMetrics { voltage, current, power in
                guard voltage.isFinite, current.isFinite, power.isFinite else {
                    finish(.failure(XPCError.commandFailed("Battery sample unavailable")))
                    return
                }
                finish(.success(SMCBatteryReading(
                    batteryVoltage: voltage, batteryCurrent: current, batteryPower: power
                )))
            }
        }
    }

    private func fetchSMCAdapterData() async -> SMCAdapterReading? {
        try? await performXPCRequest(timeout: .seconds(3)) { finish in
            guard let helper = xpcManager.getHelper(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.helperUnavailable))
                return
            }
            helper.readAdapterMetrics { voltage, current, power in
                guard voltage.isFinite, current.isFinite, power.isFinite else {
                    finish(.failure(XPCError.commandFailed("Adapter sample unavailable")))
                    return
                }
                finish(.success(SMCAdapterReading(
                    adapterVoltage: voltage, adapterCurrent: current, adapterPower: power
                )))
            }
        }
    }

    // MARK: - Real-Time SMC Poll

    private func pollSMCOnce() async {
        async let batteryResult = fetchSMCBatteryData()
        async let adapterResult = fetchSMCAdapterData()
        let battery = await batteryResult
        let adapter = await adapterResult
        guard battery != nil || adapter != nil else {
            ControlDiagnostics.shared.record("SAMPLE_ERROR", "SMC readings unavailable; keeping last valid sample")
            return
        }
        if !capabilitiesLoaded { await loadCapabilities() }
        var updatedBattery = metrics
        var updatedAdapter = adapterMetrics
        if let battery {
            updatedBattery.batteryVoltage = battery.batteryVoltage
            updatedBattery.batteryCurrent = battery.batteryCurrent
            updatedBattery.batteryPower = battery.batteryPower
            hasRealtimeBatteryReading = true
            lastRealtimeBatterySample = Date()
            // PowerTelemetryData can be tens of seconds older than SMC. Never let
            // it reverse the sign of a fresh sample after a CHIE transition.
            updatedBattery.isCharging = battery.batteryPower > 0.15
        }
        if let adapter {
            updatedAdapter.adapterVoltage = adapter.adapterVoltage
            updatedAdapter.adapterCurrent = adapter.adapterCurrent
            updatedAdapter.adapterPower = max(0, adapter.adapterPower)
            hasRealtimeAdapterReading = true
        }
        if !updatedAdapter.adapterConnected {
            updatedAdapter.adapterVoltage = 0
            updatedAdapter.adapterCurrent = 0
            updatedAdapter.adapterPower = 0
            updatedBattery.isCharging = false
        }
        updatedAdapter.systemPower = max(0, updatedAdapter.adapterPower - updatedBattery.batteryPower)
        if updatedBattery != metrics { metrics = updatedBattery }
        if updatedAdapter != adapterMetrics { adapterMetrics = updatedAdapter }
        powerSampleDate = Date()
        updateControlState(from: updatedBattery, adapter: updatedAdapter)
        let sampleLogInterval: TimeInterval = updatedAdapter.adapterConnected &&
            (updatedBattery.isCharging || updatedBattery.batteryPower < -2) ? 5 : 30
        if Date().timeIntervalSince(lastSampleLog) >= sampleLogInterval {
            lastSampleLog = Date()
            ControlDiagnostics.shared.record("SAMPLE", "soc=\(updatedBattery.batteryPercentage) hardwareSoc=\(updatedBattery.hardwareBatteryPercentage) connected=\(updatedAdapter.adapterConnected) charging=\(updatedBattery.isCharging) batteryW=\(String(format: "%.2f", updatedBattery.batteryPower)) currentA=\(String(format: "%.3f", updatedBattery.batteryCurrent)) adapterW=\(String(format: "%.2f", updatedAdapter.adapterPower)) temperature=\(updatedBattery.batteryTemperature)")
        }
    }

    // MARK: - Merge IOKit + SMC

    private func handleIOKitUpdate(
        _ newBatteryMetrics:
            BatteryMetrics,

        adapterUpdate:
            AdapterMetrics
    ) {
        hasObservedIOKitState = true
        if Date().timeIntervalSince(lastRealtimeBatterySample) >= 3 {
            powerSampleDate = Date()
        }
        logger.debug(
            "Received IOKit update"
        )

        let adapterConnectionChanged =

            adapterUpdate
                .adapterConnected

            !=

            adapterMetrics
                .adapterConnected

        if adapterConnectionChanged {

            logger.info(
                """
                Adapter state changed: \
                \(adapterUpdate.adapterConnected)
                """
            )

            // 适配器重新连接后，
            // 等下一次 SMC Poll
            // 再认为 Adapter
            // 实时数据有效。

            hasRealtimeAdapterReading =
                false
        }

        // IOKit 数据作为基础数据。

        var updatedBattery =
            newBatteryMetrics

        // 如果已经拿到过
        // SMC 实时数据，
        //
        // 就不要让 IOKit
        // 的低频数据覆盖掉它。

        if hasRealtimeBatteryReading, Date().timeIntervalSince(lastRealtimeBatterySample) < 3 {

            updatedBattery
                .batteryVoltage =
                    metrics
                    .batteryVoltage

            updatedBattery
                .batteryCurrent =
                    metrics
                    .batteryCurrent

            updatedBattery
                .batteryPower =
                    metrics
                    .batteryPower

            // 插着电时，
            // 用真实功率方向
            // 判断是否充电。

            if adapterUpdate
                .adapterConnected
            {
                updatedBattery
                    .isCharging =

                    metrics
                        .batteryPower > 0.5

            } else {

                updatedBattery
                    .isCharging =
                        false
            }
        }

        var updatedAdapter =
            adapterUpdate

        if adapterUpdate
            .adapterConnected
        {

            // 已经有实时 SMC
            // Adapter 数据时保留。

            if hasRealtimeAdapterReading {

                updatedAdapter
                    .adapterVoltage =
                        adapterMetrics
                        .adapterVoltage

                updatedAdapter
                    .adapterCurrent =
                        adapterMetrics
                        .adapterCurrent

                updatedAdapter
                    .adapterPower =
                        adapterMetrics
                        .adapterPower
            }

            // 系统实时功耗也保留。

            if adapterMetrics
                .systemPower > 0
            {
                updatedAdapter
                    .systemPower =
                        adapterMetrics
                        .systemPower
            }

        } else {

            // 拔掉电源之后
            // 立即清空 AC 输入。

            updatedAdapter
                .adapterVoltage =
                    0

            updatedAdapter
                .adapterCurrent =
                    0

            updatedAdapter
                .adapterPower =
                    0

            // systemPower 在电池供电时
            // 依然可以继续显示。

            if adapterMetrics
                .systemPower > 0
            {
                updatedAdapter
                    .systemPower =
                        adapterMetrics
                        .systemPower
            }
        }

        if updatedBattery
            != metrics
        {
            metrics =
                updatedBattery
        }

        if updatedAdapter
            != adapterMetrics
        {
            adapterMetrics =
                updatedAdapter
        }

        updateControlState(
            from:
                updatedBattery,

            adapter:
                updatedAdapter
        )
    }

    // MARK: - Control State

    private func updateControlState(
        from metrics:
            BatteryMetrics,

        adapter:
            AdapterMetrics
    ) {
        let newState =
            BatteryControlState(

                batteryPercentage:
                    metrics
                    .batteryPercentage,

                hardwareBatteryPercentage:
                    metrics
                    .hardwareBatteryPercentage,

                adapterConnected:
                    adapter
                    .adapterConnected,

                batteryTemperature:
                    metrics
                    .batteryTemperature
            )

        if newState
            != controlState
        {
            controlState =
                newState
        }
    }

    // MARK: - Native Charge Limit

    /// 通过 privileged helper
    /// 设置 macOS 原生 Manual Charge Limit。
    ///
    /// 例如：
    ///
    /// enableMCL 已开启
    /// ↓
    /// applyNativeChargeLimit(75)
    /// ↓
    /// root helper 写 Smart Charging defaults
    /// ↓
    /// powerd 建立：
    /// manualChargeLimit = 75
    ///
    /// 注意：
    ///
    /// 这里不负责 PowerUI 的
    /// enableMCL / disableMCL。
    ///
    /// PowerUI 后端下一步单独实现。
    func applyNativeChargeLimit(
        limit: Int
    ) async throws {

        try await performChargingHelperCommand { helper, reply in
            helper.applyNativeChargeLimit(limit: limit, reply: reply)
        }
    }

    // MARK: - Legacy Charging Control

    /// 传统 SMC Charging Inhibit。
    ///
    /// 你的 M4 Pro / macOS 27
    /// 当前已经实测为 unsupported。
    ///
    /// 这里继续保留，
    /// 是为了旧机器兼容。
    func manageBatteryCharging(
        enabled: Bool
    ) async throws {

        try await performChargingHelperCommand { helper, reply in
            helper.manageBatteryCharging(enabled: enabled, reply: reply)
        }
    }

    // MARK: - Force Discharge

    /// enabled = true
    ///
    /// 正常使用适配器。
    ///
    /// enabled = false
    ///
    /// CHIE Force Discharge，
    /// 强制使用电池供电。
    func manageExternalPower(
        enabled: Bool
    ) async throws {

        try await performChargingHelperCommand { helper, reply in
            helper.manageExternalPower(enabled: enabled, reply: reply)
        }
    }

    // MARK: - MagSafe LED

    func manageMagsafeLED(
        target:
            MagSafeLEDState
    ) async throws {

        try await performChargingHelperCommand { helper, reply in
            helper.manageMagsafeLED(target: target.rawValue, reply: reply)
        }
    }

    func diagnosticControlStatus() async -> String {
        do {
            return try await performXPCRequest(timeout: .seconds(3)) { finish in
                guard let helper = ChargingHelperManager.shared.getHelper(
                    errorHandler: { finish(.failure($0)) }
                ) else {
                    finish(.failure(XPCError.helperUnavailable))
                    return
                }
                helper.getControlStatus { finish(.success($0)) }
            }
        } catch { return "helper status error: \(error.localizedDescription)" }
    }

    // MARK: - Stop

    func stop() {

        logger.info(
            "BatteryService stopping"
        )

        ioKitMonitorTask?
            .cancel()

        ioKitMonitorTask =
            nil

        smcPollTask?
            .cancel()

        nextPollSleepTask?.cancel()
        nextPollSleepTask = nil

        smcPollTask =
            nil

        delayedPollTask?
            .cancel()

        delayedPollTask =
            nil

        xpcManager
            .disconnect()
    }
}
