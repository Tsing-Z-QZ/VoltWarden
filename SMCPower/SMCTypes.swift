import Foundation

public struct SMCBatteryReading: Sendable {
    public let batteryVoltage: Double
    public let batteryCurrent: Double
    public let batteryPower: Double

    public init(
        batteryVoltage: Double,
        batteryCurrent: Double,
        batteryPower: Double
    ) {
        self.batteryVoltage = batteryVoltage
        self.batteryCurrent = batteryCurrent
        self.batteryPower = batteryPower
    }
}

public struct SMCAdapterReading: Sendable {
    public let adapterVoltage: Double
    public let adapterCurrent: Double
    public let adapterPower: Double

    public init(
        adapterVoltage: Double,
        adapterCurrent: Double,
        adapterPower: Double
    ) {
        self.adapterVoltage = adapterVoltage
        self.adapterCurrent = adapterCurrent
        self.adapterPower = adapterPower
    }
}

public struct DeviceCapabilities: Sendable {
    public let chargingControl: Bool
    public let adapterControl: Bool
    public let hasMagSafe: Bool
    public let magsafeLEDControl: Bool

    public init(
        chargingControl: Bool,
        adapterControl: Bool,
        hasMagSafe: Bool,
        magsafeLEDControl: Bool
    ) {
        self.chargingControl = chargingControl
        self.adapterControl = adapterControl
        self.hasMagSafe = hasMagSafe
        self.magsafeLEDControl = magsafeLEDControl
    }

    public static func from(
        battery: BatteryCapabilities,
        adapter: AdapterCapabilities
    ) -> DeviceCapabilities {
        DeviceCapabilities(
            chargingControl: battery.inhibitChargeControl,
            adapterControl: battery.forceDischargeControl,
            hasMagSafe: adapter.magSafeControl,
            magsafeLEDControl: adapter.magSafeControl
        )
    }
}
public struct ChargePolicyPlan: Equatable, Sendable {
    public let nativeLimit: Int
    public let shouldDischarge: Bool
    public let chargingGateCommand: Bool?
    public let forceDischargeCommand: Bool
}

public struct NativeLimitResetPolicy: Sendable {
    private var lastTarget: Int?
    public init() {}

    public mutating func beginRequest(target: Int) -> Bool {
        guard (50...100).contains(target) else { return false }
        let changed = lastTarget != target
        lastTarget = target
        return target < 100 && changed
    }
}

public enum ChargePolicy {
    public static func plan(
        percentage: Int,
        normalLimit: Int,
        topUpActive: Bool,
        adapterConnected: Bool,
        automaticDischargeEnabled: Bool,
        chargingGateSupported: Bool,
        forceDischargeSupported: Bool
    ) -> ChargePolicyPlan {
        let target = topUpActive && adapterConnected ? 100 : normalLimit
        let discharge = adapterConnected && automaticDischargeEnabled &&
            forceDischargeSupported && percentage > target
        // Native MCL can drain an over-target battery even with CHIE cleared.
        // On devices without a separate charging gate, passive holding therefore
        // uses the present SoC. The saved user limit remains unchanged; unplugging
        // restores it, and subsequent lower readings lower this temporary ceiling.
        let passiveHold = adapterConnected && !topUpActive &&
            !automaticDischargeEnabled && !chargingGateSupported && percentage > target
        return ChargePolicyPlan(
            nativeLimit: passiveHold ? min(100, percentage) : target,
            shouldDischarge: discharge,
            chargingGateCommand: gateCommand(
                supported: chargingGateSupported,
                desiredCharging: !(discharge || percentage >= target)
            ),
            forceDischargeCommand: discharge
        )
    }

    public static func isCurrent(_ revision: Int, current: Int) -> Bool {
        revision == current
    }

    public static func gateCommand(
        supported: Bool, desiredCharging: Bool
    ) -> Bool? {
        supported ? desiredCharging : nil
    }
}
