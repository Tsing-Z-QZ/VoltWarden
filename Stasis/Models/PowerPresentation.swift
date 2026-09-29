import Foundation

struct PowerFlowSnapshot {
    let batteryPower: Double
    let adapterPower: Double
    let systemPower: Double
    let powerSource: PowerSource
    let chargingMode: ChargingMode

    static func resolve(battery: BatteryMetrics, adapter: AdapterMetrics) -> Self {
        let batteryWatts = battery.batteryPower.isFinite ? battery.batteryPower : 0
        let adapterWatts = adapter.adapterPower.isFinite ? max(0, adapter.adapterPower) : 0
        if !adapter.adapterConnected || (batteryWatts < -0.15 && !battery.externalConnected) {
            // CHIE can leave a cable attached and an old adapter sample behind.
            let discharge = min(0, batteryWatts)
            return Self(batteryPower: discharge, adapterPower: 0, systemPower: -discharge,
                        powerSource: .battery, chargingMode: .discharging)
        }
        // Sub-watt and roughly 1 W negative readings are common near hold.
        // They remain available in BatteryMetrics, but must not flip the UI
        // between "not charging" and "battery supplying power".
        if batteryWatts <= -2 {
            return Self(batteryPower: batteryWatts, adapterPower: adapterWatts,
                        systemPower: adapterWatts - batteryWatts,
                        powerSource: adapterWatts > 0.15 ? .both : .battery,
                        chargingMode: .discharging)
        }
        let presentedBatteryWatts = batteryWatts < 0 ? 0 : batteryWatts
        return Self(batteryPower: presentedBatteryWatts, adapterPower: adapterWatts,
                    systemPower: max(0, adapterWatts - presentedBatteryWatts),
                    powerSource: .acAdapter,
                    chargingMode: batteryWatts > 0.15 ? .charging : .pluggedIn)
    }
}

/// Presentation-only estimator. A charge target is deliberately not an input.
struct UnpluggedRuntimeEstimator {
    private var capacityMAh: Double?
    private var maximumCapacityMAh: Double?
    private var voltage: Double?
    private var smoothedPower: Double?
    private var lastPowerSampleDate: Date?
    private var lastEnergySampleDate: Date?
    private var lastVoltageSampleDate: Date?
    private var lastReviewDate: Date?
    private var wakeRecoveryUntil: Date?
    private var startupLowPowerSince: Date?
    private(set) var minutes: Int?
    private(set) var isUsingPreviousReading = false

    mutating func noteWake(now: Date = Date()) {
        // The first SMC readings after sleep may describe a near-idle machine,
        // not the user's resumed workload. Keep the last useful estimate.
        wakeRecoveryUntil = now.addingTimeInterval(60)
    }

    mutating func update(
        remainingCapacityMAh: Double?, fullCapacityMAh: Double?,
        actualPercentage: Int, batteryVoltage: Double,
        systemPower: Double, sampleDate: Date?, now: Date = Date()
    ) {
        if let fullCapacityMAh, fullCapacityMAh.isFinite,
           (500...50_000).contains(fullCapacityMAh) {
            maximumCapacityMAh = fullCapacityMAh
        }
        if let remainingCapacityMAh, remainingCapacityMAh.isFinite,
           remainingCapacityMAh >= 0,
           remainingCapacityMAh <= (maximumCapacityMAh ?? 50_000) * 1.1 {
            capacityMAh = remainingCapacityMAh
            lastEnergySampleDate = sampleDate
        } else if let maximumCapacityMAh, (0...100).contains(actualPercentage) {
            capacityMAh = maximumCapacityMAh * Double(actualPercentage) / 100
            lastEnergySampleDate = sampleDate
        }
        if batteryVoltage.isFinite, (5...30).contains(batteryVoltage) {
            voltage = batteryVoltage
            lastVoltageSampleDate = sampleDate
        }
        let validNewPowerSample = sampleDate != nil && sampleDate != lastPowerSampleDate &&
            systemPower.isFinite && (0.8...300).contains(systemPower)
        if let sampleDate, validNewPowerSample,
           wakeRecoveryUntil.map({ now >= $0 && systemPower >= 5 }) ?? true {
            // On cold launch, a very low first reading is also unrepresentative.
            // A real sustained low load can still establish an estimate later.
            if minutes == nil && smoothedPower == nil && systemPower < 5 {
                startupLowPowerSince = startupLowPowerSince ?? sampleDate
            } else {
                startupLowPowerSince = nil
            }
            if let startupLowPowerSince,
               sampleDate.timeIntervalSince(startupLowPowerSince) < 120 {
                // Wait for either a normal active-load reading or two minutes
                // of genuinely sustained light use.
            } else {
                wakeRecoveryUntil = nil
                if let previousDate = lastPowerSampleDate, let previousPower = smoothedPower {
                    let elapsed = max(0, sampleDate.timeIntervalSince(previousDate))
                    // Time-based smoothing behaves the same with a closed or open menu.
                    let weight = 1 - exp(-elapsed / 60)
                    smoothedPower = previousPower + weight * (systemPower - previousPower)
                } else {
                    smoothedPower = systemPower
                }
                lastPowerSampleDate = sampleDate
            }
        }
        isUsingPreviousReading = [lastPowerSampleDate, lastEnergySampleDate, lastVoltageSampleDate]
            .contains { $0.map { now.timeIntervalSince($0) > 15 } ?? true } || wakeRecoveryUntil != nil
        guard wakeRecoveryUntil == nil else { return }
        guard let capacityMAh, let voltage, let smoothedPower else { return }
        let estimate = capacityMAh * voltage / 1000 / smoothedPower * 60
        guard estimate.isFinite, (0...4_320).contains(estimate) else { return }
        let candidate = capacityMAh == 0 ? 0 : max(1, Int((estimate / 5).rounded()) * 5)
        if minutes == nil || candidate == 0 {
            minutes = candidate
            lastReviewDate = now
        } else if now.timeIntervalSince(lastReviewDate ?? .distantPast) >= 300 {
            lastReviewDate = now
            // Keep small workload changes out of the UI instead of displaying a live gauge.
            if let previous = minutes, abs(candidate - previous) >= max(10, Int(Double(previous) * 0.15)) {
                minutes = candidate
            }
        }
    }
}

struct ChargeTimeEstimator {
    private var remainingCapacityMAh: Double?
    private var fullCapacityMAh: Double?
    private var chargingCurrent: Double?
    private var lastCurrentDate: Date?
    private var currentWarmupUntil: Date?
    private var lastReviewDate: Date?
    private var displayedTarget: Int?
    private(set) var minutes: Int?

    mutating func update(metrics: BatteryMetrics, target: Int, sampleDate: Date?, now: Date = Date()) {
        if let full = metrics.fullCapacityMAh, full.isFinite, (500...50_000).contains(full) {
            fullCapacityMAh = full
        }
        if let remaining = metrics.remainingCapacityMAh, remaining.isFinite,
           remaining >= 0, remaining <= (fullCapacityMAh ?? 50_000) * 1.1 {
            remainingCapacityMAh = remaining
        } else if let fullCapacityMAh, (0...100).contains(metrics.hardwareBatteryPercentage) {
            remainingCapacityMAh = fullCapacityMAh * Double(metrics.hardwareBatteryPercentage) / 100
        }
        let current = metrics.batteryCurrent > 0.05
            ? metrics.batteryCurrent
            : (metrics.batteryVoltage > 5 ? metrics.batteryPower / metrics.batteryVoltage : 0)
        if metrics.batteryPower > 0.15, current.isFinite, (0.05...30).contains(current),
           let sampleDate, sampleDate != lastCurrentDate {
            if lastCurrentDate.map({ sampleDate.timeIntervalSince($0) > 30 }) ?? true {
                currentWarmupUntil = now.addingTimeInterval(10)
            }
            if let lastCurrentDate, let chargingCurrent, sampleDate.timeIntervalSince(lastCurrentDate) < 300 {
                // Current ramps up rapidly when charging starts. Do not freeze
                // the first trickle-current ETA for a full display interval.
                let timeConstant: Double = now <= (currentWarmupUntil ?? .distantPast) ? 2 : 15
                let weight = 1 - exp(-max(0, sampleDate.timeIntervalSince(lastCurrentDate)) / timeConstant)
                self.chargingCurrent = chargingCurrent + weight * (current - chargingCurrent)
            } else {
                chargingCurrent = current
            }
            lastCurrentDate = sampleDate
        }

        let targetChanged = displayedTarget != target
        if targetChanged {
            displayedTarget = target
            minutes = nil
            lastReviewDate = nil
        }
        var candidate: Int?
        if metrics.hardwareBatteryPercentage >= target {
            candidate = 0
        } else if let fullCapacityMAh, let remainingCapacityMAh {
            let needed = max(0, fullCapacityMAh * Double(target) / 100 - remainingCapacityMAh)
            if needed == 0 {
                candidate = 0
            } else if let chargingCurrent, let lastCurrentDate, now.timeIntervalSince(lastCurrentDate) <= 300 {
                let estimate = needed / (chargingCurrent * 1000) * 60
                if estimate.isFinite, (0...4_320).contains(estimate) {
                    candidate = max(1, Int(estimate.rounded(.up)))
                }
            }
        }
        // IOKit can provide time-to-full while raw capacity is temporarily unavailable.
        if candidate == nil, target == 100, let systemMinutes = metrics.timeToFullMinutes, (1...4_320).contains(systemMinutes) {
            candidate = systemMinutes
        }
        guard let candidate else { return }
        let reviewInterval: TimeInterval = now <= (currentWarmupUntil ?? .distantPast) ? 5 : 30
        if minutes == nil || candidate == 0 || targetChanged ||
            now.timeIntervalSince(lastReviewDate ?? .distantPast) >= reviewInterval {
            minutes = candidate
            lastReviewDate = now
        }
    }
}

enum TimeEstimateKind: Equatable {
    case charge(target: Int)
    case runtime

    static func resolve(chargingMode: ChargingMode, adapterConnected: Bool,
                        actualPercentage: Int, effectiveTarget: Int,
                        manageCharging: Bool, calibrationDischarging: Bool,
                        forceDischarging: Bool) -> Self {
        if chargingMode == .charging && (!manageCharging || actualPercentage < effectiveTarget) {
            return .charge(target: manageCharging ? effectiveTarget : 100)
        }
        // Switch the label as soon as an upward target is submitted; measured
        // charging current (or its recent cache) supplies the number.
        if adapterConnected && manageCharging && actualPercentage < effectiveTarget &&
            !calibrationDischarging && !forceDischarging {
            return .charge(target: effectiveTarget)
        }
        return .runtime
    }
}

/// Pointer drags commit once; keyboard/accessibility changes commit immediately.
struct ChargeLimitDraft {
    private(set) var value: Double = 75
    private(set) var isEditing = false

    mutating func begin(current: Int) {
        value = Double(current)
        isEditing = true
    }

    mutating func update(_ newValue: Double) -> Int? {
        guard newValue.isFinite else { return nil }
        value = min(max(newValue, 50), 100)
        return isEditing ? nil : Int(value.rounded())
    }

    mutating func finish(enabled: Bool) -> Int? {
        guard isEditing else { return nil }
        isEditing = false
        return enabled ? Int(value.rounded()) : nil
    }

    mutating func cancel() { isEditing = false }
}
