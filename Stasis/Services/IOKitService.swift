import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os.log

@MainActor
class IOKitService {

    // MARK: - State

    private var systemHealth: Double = 0

    private var healthTask: Task<Void, Never>?

    private var notificationPort: IONotificationPortRef?

    private var interestNotification: io_object_t = 0

    private var batteryService: io_service_t = 0

    private var continuation:
        AsyncStream<(BatteryMetrics, AdapterMetrics)>.Continuation?

    private let logger = Logger(
        subsystem: "com.srimanachanta.stasis",
        category: "IOKitService"
    )

    // MARK: - Metrics Stream

    func metricsStream()
        -> AsyncStream<(BatteryMetrics, AdapterMetrics)>
    {
        AsyncStream { continuation in

            self.continuation = continuation

            continuation.onTermination = { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stop()
                }
            }

            self.startNotifications()
        }
    }

    // MARK: - Start Monitoring

    private func startNotifications() {

        logger.info("Starting IOKit monitoring")

        batteryService = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )

        if batteryService == 0 {
            logger.error(
                "Failed to get AppleSmartBattery service"
            )
        }

        guard batteryService != 0 else {
            return
        }

        notificationPort =
            IONotificationPortCreate(
                kIOMainPortDefault
            )

        guard let notificationPort else {
            logger.error(
                "Failed to create IONotificationPort"
            )
            return
        }

        let notificationSource =
            IONotificationPortGetRunLoopSource(
                notificationPort
            )
            .takeUnretainedValue()

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            notificationSource,
            .commonModes
        )

        let context =
            UnsafeMutableRawPointer(
                Unmanaged.passUnretained(self)
                    .toOpaque()
            )

        let callback:
            IOServiceInterestCallback =
        {
            refcon,
            _,
            _,
            _ in

            guard let refcon else {
                return
            }

            let monitor =
                Unmanaged<IOKitService>
                .fromOpaque(refcon)
                .takeUnretainedValue()

            MainActor.assumeIsolated {
                monitor.emitMetrics()
            }
        }

        let result =
            IOServiceAddInterestNotification(
                notificationPort,
                batteryService,
                kIOGeneralInterest,
                callback,
                context,
                &interestNotification
            )

        if result == KERN_SUCCESS {

            logger.info(
                """
                IORegistry interest notification \
                registered for AppleSmartBattery
                """
            )

        } else {

            logger.error(
                """
                Failed to register \
                interest notification: \(result)
                """
            )
        }

        // 启动时立即读取一次
        emitMetrics()

        // 电池健康度不需要高频刷新
        // system_profiler 本身比较重，所以每小时一次
        healthTask =
            Task { [weak self] in

                while !Task.isCancelled {

                    let health =
                        await Task.detached(
                            priority: .utility
                        ) {
                            () -> Double? in

                            let process = Process()

                            process.executableURL =
                                URL(
                                    fileURLWithPath:
                                        "/usr/sbin/system_profiler"
                                )

                            process.arguments = [
                                "SPPowerDataType",
                                "-json"
                            ]

                            let pipe = Pipe()

                            process.standardOutput =
                                pipe

                            process.standardError =
                                FileHandle.nullDevice

                            do {
                                try process.run()
                            } catch {
                                return nil
                            }

                            let data =
                                pipe.fileHandleForReading
                                .readDataToEndOfFile()

                            process.waitUntilExit()

                            guard
                                let json =
                                    try?
                                    JSONSerialization
                                    .jsonObject(
                                        with: data
                                    )
                                    as? [String: Any],

                                let entries =
                                    json[
                                        "SPPowerDataType"
                                    ]
                                    as? [[String: Any]]

                            else {
                                return nil
                            }

                            for entry in entries {

                                if
                                    let info =
                                        entry[
                                            "sppower_battery_health_info"
                                        ]
                                        as? [String: Any],

                                    let text =
                                        info[
                                            "sppower_battery_health_maximum_capacity"
                                        ]
                                        as? String
                                {
                                    return Double(
                                        text
                                            .replacingOccurrences(
                                                of: "%",
                                                with: ""
                                            )
                                    )
                                }
                            }

                            return nil
                        }
                        .value

                    if let health {

                        self?.systemHealth =
                            health

                        self?.emitMetrics()
                    }

                    try?
                        await Task.sleep(
                            for:
                                .seconds(
                                    3600
                                )
                        )
                }
            }
    }

    // MARK: - Stop

    private func stop() {

        healthTask?.cancel()
        healthTask = nil

        if interestNotification != 0 {

            IOObjectRelease(
                interestNotification
            )

            interestNotification = 0
        }

        if let notificationPort {

            let source =
                IONotificationPortGetRunLoopSource(
                    notificationPort
                )
                .takeUnretainedValue()

            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                source,
                .commonModes
            )

            IONotificationPortDestroy(
                notificationPort
            )

            self.notificationPort = nil
        }

        if batteryService != 0 {

            IOObjectRelease(
                batteryService
            )

            batteryService = 0
        }

        continuation = nil
    }

    // MARK: - Emit Metrics

    private func emitMetrics() {

        let powerInfo =
            getPowerSourceInfo()
            as? [String: Any]

        var batteryMetrics =
            BatteryMetrics()

        var adapterMetrics =
            AdapterMetrics()

        // MARK: 电池百分比

        guard let percentages = getBatteryPercentages(powerInfo: powerInfo),
              let externalConnected = isExternalPowerFlowing(powerInfo: powerInfo),
              let adapterConnected = isAdapterPhysicallyConnected(powerInfo: powerInfo) else {
            // Missing IOKit data is not a physical unplug or a 0% battery.
            return
        }

        batteryMetrics.batteryPercentage =
            percentages.displayed

        batteryMetrics.hardwareBatteryPercentage =
            percentages.hardware

        // MARK: 系统充电状态

        //
        // 这里保留 macOS 自己提供的 IsCharging。
        //
        // 不再简单使用：
        //
        // batteryPower > 0.5
        //
        // 来覆盖它。
        //
        // 因为接近满电、涓流充电时，
        // 电池输入功率可能非常低，
        // 但系统仍然认为正在充电。
        //

        let systemIsCharging =
            powerInfo?[
                kIOPSIsChargingKey
            ]
            as? Bool
            ?? false

        batteryMetrics.isCharging =
            systemIsCharging

        // MARK: 电池容量

        let capacities =
            getBatteryCapacities()

        if capacities.max > 0 {
            batteryMetrics.fullCapacityMAh = Double(capacities.max)
            if capacities.current > 0 || percentages.hardware == 0 {
                batteryMetrics.remainingCapacityMAh = Double(capacities.current)
            }
        }

        // MARK: 剩余时间

        if systemIsCharging {

            batteryMetrics.timeRemaining =
                getTimeToFull(
                    powerInfo:
                        powerInfo
                )
                ?? -1

        } else {

            batteryMetrics.timeRemaining =
                getTimeRemaining(
                    powerInfo:
                        powerInfo
                )
                ?? -1
        }

        // MARK: 电池健康度

        batteryMetrics.batteryHealth =
            systemHealth

        // MARK: 外部电源状态

        // ExternalConnected describes the current power route. CHIE deliberately
        // makes it false while the cable is still attached. AdapterDetails is the
        // physical cable signal used by the control policy and Top Up unplug edge.
        batteryMetrics.externalConnected = externalConnected
        adapterMetrics.adapterConnected = adapterConnected
        if adapterConnected {
            adapterMetrics.negotiatedWatts = AdapterPowerSpecification.watts(
                details: getPropertyValue(batteryService, key: "AdapterDetails"),
                rawDetails: getPropertyValue(batteryService, key: "AppleRawAdapterDetails")
            )
        }

        // MARK: 电压 / 电流

        let pack =
            getBatteryPackData()
            ?? [:]

        batteryMetrics.batteryVoltage =
            doubleValue(
                pack["Voltage"]
            )
            / 1000.0

        batteryMetrics.batteryCurrent =
            signedValue(
                pack[
                    "InstantAmperage"
                ]
                ?? pack[
                    "Amperage"
                ]
            )
            / 1000.0

        batteryMetrics.batteryPower =
            batteryMetrics.batteryVoltage
            * batteryMetrics.batteryCurrent

        // MARK: Power Telemetry

        //
        // PowerTelemetryData 用于：
        //
        // - Battery Power
        // - Adapter Power
        // - System Power
        //

        if let telemetry =
            getPowerTelemetry()
        {
            adapterMetrics.adapterPower =
                adapterMetrics
                    .adapterConnected
                ? telemetry.adapterPower
                : 0

            adapterMetrics.systemPower =
                telemetry.systemPower
        }

        // MARK: 充电剩余时间备用算法

        //
        // 部分 macOS / Apple Silicon
        // 不提供 Time To Full Charge。
        //
        // 这时根据剩余容量和充电电流
        // 做一个大致估算。
        //

        if systemIsCharging,
           batteryMetrics.timeRemaining < 0
        {
            let chargingCurrent =
                getEstimatedChargingCurrent(
                    batteryMetrics:
                        batteryMetrics
                )

            if chargingCurrent > 0.05,
               capacities.max > 0,
               capacities.current >= 0,
               capacities.current
                    < capacities.max
            {
                let remainingCapacity =
                    capacities.max
                    - capacities.current

                let estimatedMinutes =
                    Int(
                        Double(
                            remainingCapacity
                        )
                        /
                        (
                            chargingCurrent
                            * 1000.0
                        )
                        * 60.0
                    )

                if isReasonableTimeEstimate(
                    estimatedMinutes
                ) {
                    batteryMetrics.timeRemaining =
                        estimatedMinutes
                }
            }
        }

        // MARK: 放电剩余时间备用算法

        if !systemIsCharging,
           batteryMetrics.batteryPower
                < -0.5
        {
            let minutes: Int =
                getPropertyValue(
                    batteryService,
                    key:
                        "TimeRemaining"
                )
                ?? -1

            if isReasonableTimeEstimate(
                minutes
            ) {
                batteryMetrics.timeRemaining =
                    minutes
            }

            if batteryMetrics.timeRemaining
                < 0,
               batteryMetrics.batteryCurrent
                < -0.05,
               capacities.current > 0
            {
                let estimatedMinutes =
                    Int(
                        Double(
                            capacities.current
                        )
                        /
                        (
                            -batteryMetrics
                                .batteryCurrent
                            * 1000.0
                        )
                        * 60.0
                    )

                if isReasonableTimeEstimate(
                    estimatedMinutes
                ) {
                    batteryMetrics.timeRemaining =
                        estimatedMinutes
                }
            }
        }

        // MARK: 电池温度

        if let temperature =
            getBatteryTemperature(
                powerInfo:
                    powerInfo
            )
        {
            batteryMetrics.batteryTemperature =
                temperature
        }

        // MARK: 循环次数

        batteryMetrics.cycleCount =
            getPropertyValue(
                batteryService,
                key:
                    "CycleCount"
            )
            ?? 0

        logger.debug(
            """
            IOKit metrics: \
            battery=\(batteryMetrics.batteryPercentage)%, \
            hardwareBattery=\(batteryMetrics.hardwareBatteryPercentage)%, \
            health=\(batteryMetrics.batteryHealth)%, \
            charging=\(batteryMetrics.isCharging), \
            temp=\(batteryMetrics.batteryTemperature)°C, \
            cycles=\(batteryMetrics.cycleCount), \
            timeRemaining=\(batteryMetrics.timeRemaining), \
            externalConnected=\(batteryMetrics.externalConnected), \
            adapterConnected=\(adapterMetrics.adapterConnected), \
            batteryPower=\(batteryMetrics.batteryPower)W, \
            adapterPower=\(adapterMetrics.adapterPower)W, \
            systemPower=\(adapterMetrics.systemPower)W
            """
        )

        if systemIsCharging, (1...4_320).contains(batteryMetrics.timeRemaining) {
            batteryMetrics.timeToFullMinutes = batteryMetrics.timeRemaining
        }

        continuation?.yield(
            (
                batteryMetrics,
                adapterMetrics
            )
        )
    }

    // MARK: - Manual Refresh

    func refreshMetrics() {

        guard batteryService != 0 else {
            return
        }

        emitMetrics()
    }

    // MARK: - Power Source Info

    private nonisolated func getPowerSourceInfo()
        -> CFDictionary?
    {
        let snapshot =
            IOPSCopyPowerSourcesInfo()
            .takeRetainedValue()

        let sources =
            IOPSCopyPowerSourcesList(
                snapshot
            )
            .takeRetainedValue()
            as Array

        guard let source =
            sources.first
        else {
            return nil
        }

        return
            IOPSGetPowerSourceDescription(
                snapshot,
                source
            )
            .takeUnretainedValue()
    }

    // MARK: - IORegistry Property

    private nonisolated func getPropertyValue<T>(
        _ service: io_service_t,
        key: String
    ) -> T? {

        guard
            let property =
                IORegistryEntryCreateCFProperty(
                    service,
                    key as CFString,
                    kCFAllocatorDefault,
                    0
                )
        else {
            return nil
        }

        return property
            .takeRetainedValue()
            as? T
    }

    // MARK: - Battery Percentage

    private func getBatteryPercentages(powerInfo: [String: Any]?) -> (displayed: Int, hardware: Int)? {
        let registryPercentage: Int? = getPropertyValue(batteryService, key: "CurrentCapacity")
        guard let percentage = powerInfo?[kIOPSCurrentCapacityKey] as? Int ?? registryPercentage,
              (0...100).contains(percentage) else { return nil }
        let rawCurrent: Int? = getPropertyValue(batteryService, key: "AppleRawCurrentCapacity")
        let rawMaximum: Int? = getPropertyValue(batteryService, key: "AppleRawMaxCapacity")
        if let rawCurrent, let rawMaximum, rawMaximum > 0 {
            return (percentage, min(100, max(0, Int(Double(rawCurrent) / Double(rawMaximum) * 100))))
        }
        return (percentage, min(100, max(0, registryPercentage ?? percentage)))
    }

    // MARK: - Time Remaining

    private func getTimeRemaining(
        powerInfo:
            [String: Any]?
    ) -> Int? {

        guard
            let timeToEmpty =
                powerInfo?[
                    kIOPSTimeToEmptyKey
                ]
                as? Int,

            timeToEmpty > 0,

            timeToEmpty
                != Int(
                    kIOPSTimeRemainingUnknown
                )

        else {
            return nil
        }

        return
            isReasonableTimeEstimate(
                timeToEmpty
            )
            ? timeToEmpty
            : nil
    }

    private func getTimeToFull(
        powerInfo:
            [String: Any]?
    ) -> Int? {

        guard
            let timeToFull =
                powerInfo?[
                    kIOPSTimeToFullChargeKey
                ]
                as? Int,

            timeToFull > 0,

            timeToFull
                != Int(
                    kIOPSTimeRemainingUnknown
                )

        else {
            return nil
        }

        return
            isReasonableTimeEstimate(
                timeToFull
            )
            ? timeToFull
            : nil
    }

    private func isReasonableTimeEstimate(
        _ minutes: Int
    ) -> Bool {

        // 0 ～ 48 小时以内认为有效
        // 主要过滤 65535 等无效值

        minutes > 0
            && minutes <= 2880
    }

    // MARK: - Adapter State

    private func isExternalPowerFlowing(powerInfo: [String: Any]?) -> Bool? {
        if let connected: Bool = getPropertyValue(batteryService, key: "ExternalConnected") {
            return connected
        }
        if let source = powerInfo?[kIOPSPowerSourceStateKey] as? String {
            if source == kIOPSACPowerValue { return true }
            if source == kIOPSBatteryPowerValue { return false }
        }
        return nil
    }

    private func isAdapterPhysicallyConnected(powerInfo: [String: Any]?) -> Bool? {
        // CHIE changes ExternalConnected and the IOPS state to battery power, so
        // positive AdapterDetails must win while force discharge is active.
        if let adapterDetails: [String: Any] = getPropertyValue(
            batteryService,
            key: "AdapterDetails"
        ), let watts = integerValue(adapterDetails["Watts"]), watts > 0 {
            return true
        }

        if let rawDetails: [[String: Any]] = getPropertyValue(
            batteryService,
            key: "AppleRawAdapterDetails"
        ), rawDetails.contains(where: {
            guard let watts = integerValue($0["Watts"]) else { return false }
            return watts > 0
        }) {
            return true
        }

        if let connected: Bool = getPropertyValue(batteryService, key: "ExternalConnected") {
            return connected
        }
        if let source = powerInfo?[kIOPSPowerSourceStateKey] as? String {
            if source == kIOPSACPowerValue { return true }
            if source == kIOPSBatteryPowerValue { return false }
        }
        return nil
    }

    // MARK: - Battery Temperature

    private func getBatteryTemperature(
        powerInfo:
            [String: Any]?
    ) -> Double? {

        //
        // AppleSmartBattery 的 Temperature
        // 常见格式类似：
        //
        // 3125 → 31.25°C
        //
        // 所以这里不再使用：
        //
        // raw / 10 - 273.15
        //
        // 那套 decikelvin 算法。
        //

        // 第一优先：
        // AppleSmartBattery 根节点 Temperature

        if let rawTemperature:
            Int =
            getPropertyValue(
                batteryService,
                key:
                    "Temperature"
            ),
           let temperature =
            normalizeBatteryTemperature(
                rawTemperature
            )
        {
            return temperature
        }

        // 第二优先：
        // BatteryData -> Temperature

        if let packData =
            getBatteryPackData(),
           let rawTemperature =
            integerValue(
                packData[
                    "Temperature"
                ]
            ),
           let temperature =
            normalizeBatteryTemperature(
                rawTemperature
            )
        {
            return temperature
        }

        // 第三优先：
        // IOPS Temperature

        if let powerInfo,
           let rawTemperature =
            integerValue(
                powerInfo[
                    kIOPSTemperatureKey
                ]
            ),
           let temperature =
            normalizeBatteryTemperature(
                rawTemperature
            )
        {
            return temperature
        }

        // 最后：
        // VirtualTemperature 仅作兜底

        if let rawVirtualTemperature:
            Int =
            getPropertyValue(
                batteryService,
                key:
                    "VirtualTemperature"
            ),
           let temperature =
            normalizeBatteryTemperature(
                rawVirtualTemperature
            )
        {
            return temperature
        }

        return nil
    }

    private nonisolated func
        normalizeBatteryTemperature(
            _ rawValue: Int
        ) -> Double?
    {
        guard rawValue > 0 else {
            return nil
        }

        //
        // 常见 AppleSmartBattery：
        //
        // 3125 -> 31.25°C
        //
        if rawValue >= 1000 {

            let celsius =
                Double(
                    rawValue
                )
                / 100.0

            if (0...80)
                .contains(
                    celsius
                )
            {
                return celsius
            }
        }

        //
        // 某些备用来源可能提供：
        //
        // 312 -> 31.2°C
        //
        if rawValue >= 100 {

            let celsius =
                Double(
                    rawValue
                )
                / 10.0

            if (0...80)
                .contains(
                    celsius
                )
            {
                return celsius
            }
        }

        //
        // 极少数接口直接返回摄氏度
        //
        let direct =
            Double(
                rawValue
            )

        if (0...80)
            .contains(
                direct
            )
        {
            return direct
        }

        return nil
    }

    // MARK: - Battery Capacity

    private func getBatteryCapacities()
        -> (
            current: Int,
            max: Int,
            design: Int
        )
    {
        let rootData:
            [String: Any] =
            getPropertyValue(
                batteryService,
                key:
                    "BatteryData"
            )
            ?? [:]

        let packData =
            getBatteryPackData()
            ?? [:]

        let currentCapacity =

            integerValue(
                rootData[
                    "RemainingCapacity"
                ]
            )

            ?? integerValue(
                packData[
                    "AppleRawCurrentCapacity"
                ]
            )

            ?? getPropertyValue(
                batteryService,
                key:
                    "AppleRawCurrentCapacity"
            )

            ?? 0

        let maxCapacity =

            integerValue(
                rootData[
                    "FullChargeCapacity"
                ]
            )

            ?? integerValue(
                packData[
                    "AppleRawMaxCapacity"
                ]
            )

            ?? getPropertyValue(
                batteryService,
                key:
                    "AppleRawMaxCapacity"
            )

            ?? 0

        let designCapacity =

            integerValue(
                rootData[
                    "DesignCapacity"
                ]
            )

            ?? integerValue(
                packData[
                    "DesignCapacity"
                ]
            )

            ?? getPropertyValue(
                batteryService,
                key:
                    "DesignCapacity"
            )

            ?? 0

        return (
            currentCapacity,
            maxCapacity,
            designCapacity
        )
    }

    // MARK: - Charging Current Estimate

    private func getEstimatedChargingCurrent(
        batteryMetrics:
            BatteryMetrics
    ) -> Double {

        // 最优先使用电池实际电流

        if batteryMetrics.batteryCurrent
            > 0.05
        {
            return
                batteryMetrics
                    .batteryCurrent
        }

        // 如果电流字段没有刷新，
        // 可以通过功率 / 电压
        // 大致推算充电电流

        if batteryMetrics.batteryPower
            > 0.5,
           batteryMetrics.batteryVoltage
            > 1
        {
            return
                batteryMetrics.batteryPower
                /
                batteryMetrics
                    .batteryVoltage
        }

        return 0
    }

    // MARK: - Power Telemetry

    func getPowerTelemetry()
        -> PowerTelemetryReading?
    {
        guard
            let telemetry:
                [String: Any] =
                getPropertyValue(
                    batteryService,
                    key:
                        "PowerTelemetryData"
                )
        else {
            return nil
        }

        guard let rawBatteryPower = telemetry["BatteryPower"] as? NSNumber,
              let rawSystemPower = telemetry["SystemLoad"] as? NSNumber,
              let rawAdapterPower = telemetry["SystemPowerIn"] as? NSNumber
        else { return nil }

        let batteryPower =
            signedValue(
                rawBatteryPower
            )
            / 1000.0

        let systemPower =
            rawSystemPower.doubleValue
            / 1000.0

        let adapterPower =
            rawAdapterPower.doubleValue
            / 1000.0

        guard
            batteryPower.isFinite,
            systemPower.isFinite,
            adapterPower.isFinite,
            systemPower >= 0,
            adapterPower >= 0
        else {
            return nil
        }

        return PowerTelemetryReading(
            batteryPower:
                batteryPower,

            adapterPower:
                adapterPower,

            systemPower:
                systemPower
        )
    }

    // MARK: - Battery Pack

    private func getBatteryPackData()
        -> [String: Any]?
    {
        let packService =
            IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching(
                    "AppleSmartBatteryPack"
                )
            )

        guard packService != 0 else {
            return nil
        }

        defer {
            IOObjectRelease(
                packService
            )
        }

        return
            getPropertyValue(
                packService,
                key:
                    "BatteryData"
            )
    }

    // MARK: - Value Helpers

    private func integerValue(
        _ value: Any?
    ) -> Int? {

        if let number =
            value as? NSNumber
        {
            return number.intValue
        }

        return value as? Int
    }

    private func doubleValue(
        _ value: Any?
    ) -> Double {

        if let number =
            value as? NSNumber
        {
            return number.doubleValue
        }

        return
            value as? Double
            ?? 0
    }

    private func signedValue(
        _ value: Any?
    ) -> Double {

        guard
            let number =
                value as? NSNumber
        else {
            return 0
        }

        return Double(
            Int64(
                bitPattern:
                    number.uint64Value
            )
        )
    }
}
