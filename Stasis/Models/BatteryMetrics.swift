import Foundation

struct BatteryMetrics: Codable, Equatable {
    var batteryPercentage: Int = 0
    var hardwareBatteryPercentage: Int = 0
    var isCharging: Bool = false
    var timeRemaining: Int = 0
    var timeToFullMinutes: Int?
    var remainingCapacityMAh: Double?
    var fullCapacityMAh: Double?

    var batteryVoltage: Double = 0
    var batteryCurrent: Double = 0
    var batteryPower: Double = 0
    var batteryTemperature: Double = 0

    var batteryHealth: Double = 0
    var cycleCount: Int = 0

    var externalConnected: Bool = false
}

struct AdapterMetrics: Equatable {
    var adapterConnected: Bool = false
    var negotiatedWatts: Int?
    var adapterVoltage: Double = 0
    var adapterCurrent: Double = 0
    var adapterPower: Double = 0
    var systemPower: Double = 0
}

enum AdapterPowerSpecification {
    static func watts(details: [String: Any]?, rawDetails: [[String: Any]]? = nil) -> Int? {
        let selected = details ?? (rawDetails?.count == 1 ? rawDetails?.first : nil)
        guard let selected else { return nil }
        let reported = (selected["Watts"] as? NSNumber)?.doubleValue
        let voltage = (selected["AdapterVoltage"] as? NSNumber)?.doubleValue
        let current = (selected["Current"] as? NSNumber)?.doubleValue
            ?? (selected["PMUConfiguration"] as? NSNumber)?.doubleValue
        var contract: Double?
        if let voltage, let current, (5_000...60_000).contains(voltage),
           (100...10_000).contains(current) {
            contract = voltage * current / 1_000_000
        }
        let candidates = [reported, contract].compactMap { $0 }
            .filter { $0.isFinite && (5...300).contains($0) }
        // AdapterDetails is the selected PD connection, not the charger's nameplate.
        // Bound a reported rating by its active voltage/current contract when available.
        return candidates.min().map { Int($0.rounded()) }
    }
}

struct PowerTelemetryReading: Equatable {
    var batteryPower: Double
    var adapterPower: Double
    var systemPower: Double
}

struct BatteryControlState: Equatable {
    var batteryPercentage: Int = 0
    var hardwareBatteryPercentage: Int = 0
    var adapterConnected: Bool = false
    var batteryTemperature: Double = 0
}
