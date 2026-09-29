import Foundation
import SMCKit

public enum SMCBatteryError: Error, Sendable, LocalizedError {
    case unsupportedCapability
    case invalidSMCData(
        key: String,
        expectedBytes: Int,
        actualBytes: Int
    )
    case verificationFailed(
        feature: String,
        expected: String,
        actual: String
    )

    public var errorDescription: String? {
        switch self {
        case .unsupportedCapability:
            return "This SMC capability is not supported on this device."

        case let .invalidSMCData(
            key,
            expectedBytes,
            actualBytes
        ):
            return
                "Invalid SMC data for \(key). Expected at least \(expectedBytes) bytes, received \(actualBytes)."

        case let .verificationFailed(
            feature,
            expected,
            actual
        ):
            return
                "\(feature) verification failed. Expected \(expected), read back \(actual)."
        }
    }
}

public struct BatteryCapabilities: Codable, Sendable {
    public let inhibitChargeControl: Bool
    public let forceDischargeControl: Bool
}

/*
 Apple Silicon charging-control paths:

 Newer firmware:
     CHTE
     00 00 00 00 = charging allowed
     01 00 00 00 = charging inhibited

 Legacy firmware:
     CH0B + CH0C
     00 = charging allowed
     02 = charging inhibited

 Force discharge:
     CHIE = 08 / 00
     or
     CH0I = 01 / 00
 */
public struct SMCBattery: Sendable {

    public let capabilities:
        BatteryCapabilities

    private let hasCH0B: Bool
    private let hasCH0C: Bool
    private let hasCHTE: Bool

    private let hasCH0I: Bool
    private let hasCHIE: Bool

    // MARK: - Probe

    public static func probe()
        throws -> SMCBattery
    {
        let hasCH0B =
            try SMCKit.shared
                .isKeyFound("CH0B")

        let hasCH0C =
            try SMCKit.shared
                .isKeyFound("CH0C")

        let hasCHTE =
            try SMCKit.shared
                .isKeyFound("CHTE")

        let hasCH0I =
            try SMCKit.shared
                .isKeyFound("CH0I")

        let hasCHIE =
            try SMCKit.shared
                .isKeyFound("CHIE")

        /*
         Legacy charge control only counts as supported
         when BOTH CH0B and CH0C exist.

         Writing only CH0C is not enough.
         */
        let hasLegacyChargeControl =
            hasCH0B && hasCH0C

        let capabilities =
            BatteryCapabilities(
                inhibitChargeControl:
                    hasCHTE
                    || hasLegacyChargeControl,

                forceDischargeControl:
                    hasCHIE
                    || hasCH0I
            )

        return SMCBattery(
            capabilities:
                capabilities,

            hasCH0B:
                hasCH0B,

            hasCH0C:
                hasCH0C,

            hasCHTE:
                hasCHTE,

            hasCH0I:
                hasCH0I,

            hasCHIE:
                hasCHIE
        )
    }

    private init(
        capabilities:
            BatteryCapabilities,

        hasCH0B: Bool,
        hasCH0C: Bool,
        hasCHTE: Bool,
        hasCH0I: Bool,
        hasCHIE: Bool
    ) {
        self.capabilities =
            capabilities

        self.hasCH0B =
            hasCH0B

        self.hasCH0C =
            hasCH0C

        self.hasCHTE =
            hasCHTE

        self.hasCH0I =
            hasCH0I

        self.hasCHIE =
            hasCHIE
    }

    // MARK: - Backend Description

    public var chargingControlBackendDescription:
        String
    {
        if hasCHTE {
            return "CHTE"
        }

        if hasCH0B && hasCH0C {
            return "CH0B+CH0C"
        }

        return "unsupported"
    }

    public var forceDischargeBackendDescription:
        String
    {
        if hasCHIE {
            return "CHIE"
        }

        if hasCH0I {
            return "CH0I"
        }

        return "unsupported"
    }

    // MARK: - Battery Reading

    public static func getVoltage()
        throws -> Double
    {
        Double(
            try SMCKit.shared
                .read("B0AV") as UInt16
        ) / 1000.0
    }

    public static func getCurrent()
        throws -> Double
    {
        Double(
            try SMCKit.shared
                .read("B0AC") as Int16
        ) / 1000.0
    }

    // MARK: - Charging

    public func getChargingInhibited()
        throws -> Bool
    {
        guard
            capabilities
                .inhibitChargeControl
        else {
            throw
                SMCBatteryError
                .unsupportedCapability
        }

        // -----------------------------------------
        // New CHTE path
        // -----------------------------------------

        if hasCHTE {

            let data =
                try readCHTE()

            /*
             CHTE:

             00 00 00 00 = enabled
             01 00 00 00 = inhibited

             Treat any non-zero value as inhibited.
             */
            return data.contains {
                $0 != 0
            }
        }

        // -----------------------------------------
        // Legacy CH0B + CH0C path
        // -----------------------------------------

        let ch0b: UInt8 =
            try SMCKit.shared
                .read("CH0B")

        let ch0c: UInt8 =
            try SMCKit.shared
                .read("CH0C")

        return
            ch0b != 0
            ||
            ch0c != 0
    }

    public func setChargingInhibited(
        _ inhibited: Bool
    ) throws {

        guard
            capabilities
                .inhibitChargeControl
        else {
            throw
                SMCBatteryError
                .unsupportedCapability
        }

        /*
         Before restoring normal charging,
         make sure force discharge is disabled.

         Otherwise we could have:

         Charging enabled
         +
         adapter still isolated.
         */
        if !inhibited {
            try clearForceDischargeKeys()
        }

        /*
         SMC writes are safety-critical.

         Write -> read back -> retry.

         We allow three attempts because on some
         firmware an SMC write may not become visible
         on the very first read.
         */
        for attempt in 1...3 {

            try writeChargingState(
                inhibited
            )

            if try chargingStateMatches(
                inhibited
            ) {
                return
            }

            if attempt < 3 {
                Thread.sleep(
                    forTimeInterval:
                        0.05
                )
            }
        }

        throw
            SMCBatteryError
            .verificationFailed(
                feature:
                    "Charging control",

                expected:
                    inhibited
                    ? "inhibited"
                    : "enabled",

                actual:
                    try chargingStateDescription()
            )
    }

    // MARK: - CHTE / CH0B + CH0C

    private func writeChargingState(
        _ inhibited: Bool
    ) throws {

        // -----------------------------------------
        // Newer firmware: CHTE
        // -----------------------------------------

        if hasCHTE {

            /*
             IMPORTANT:

             Do NOT use:

                 UInt32(1)

             here.

             We deliberately write the exact raw
             bytes expected by the SMC:

             paused:
                 01 00 00 00

             enabled:
                 00 00 00 00
             */

            let value =
                inhibited
                ? Data([
                    0x01,
                    0x00,
                    0x00,
                    0x00,
                ])
                : Data([
                    0x00,
                    0x00,
                    0x00,
                    0x00,
                ])

            try SMCKit.shared
                .writeData(
                    "CHTE",
                    value
                )

            return
        }

        // -----------------------------------------
        // Legacy firmware: CH0B + CH0C
        // -----------------------------------------

        guard
            hasCH0B,
            hasCH0C
        else {
            throw
                SMCBatteryError
                .unsupportedCapability
        }

        /*
         Correct legacy value:

         02 = pause / bypass charging
         00 = allow charging

         BOTH keys must be written.
         */

        let value:
            UInt8 =
                inhibited
                ? 0x02
                : 0x00

        try SMCKit.shared
            .write(
                "CH0B",
                value
            )

        try SMCKit.shared
            .write(
                "CH0C",
                value
            )
    }

    private func chargingStateMatches(
        _ inhibited: Bool
    ) throws -> Bool {

        if hasCHTE {

            let actual =
                try readCHTE()

            let expected =
                inhibited
                ? Data([
                    0x01,
                    0x00,
                    0x00,
                    0x00,
                ])
                : Data([
                    0x00,
                    0x00,
                    0x00,
                    0x00,
                ])

            return actual == expected
        }

        guard
            hasCH0B,
            hasCH0C
        else {
            return false
        }

        let ch0b: UInt8 =
            try SMCKit.shared
                .read("CH0B")

        let ch0c: UInt8 =
            try SMCKit.shared
                .read("CH0C")

        let expected:
            UInt8 =
                inhibited
                ? 0x02
                : 0x00

        return
            ch0b == expected
            &&
            ch0c == expected
    }

    private func chargingStateDescription()
        throws -> String
    {
        if hasCHTE {

            let data =
                try readCHTE()

            return
                "CHTE="
                +
                data
                .map {
                    String(
                        format:
                            "%02X",
                        $0
                    )
                }
                .joined()
        }

        guard
            hasCH0B,
            hasCH0C
        else {
            return "unsupported"
        }

        let ch0b: UInt8 =
            try SMCKit.shared
                .read("CH0B")

        let ch0c: UInt8 =
            try SMCKit.shared
                .read("CH0C")

        return String(
            format:
                "CH0B=%02X CH0C=%02X",
            ch0b,
            ch0c
        )
    }

    private func readCHTE()
        throws -> Data
    {
        let data =
            try SMCKit.shared
                .readData("CHTE")

        guard data.count >= 4 else {
            throw
                SMCBatteryError
                .invalidSMCData(
                    key:
                        "CHTE",

                    expectedBytes:
                        4,

                    actualBytes:
                        data.count
                )
        }

        return Data(
            data.prefix(4)
        )
    }

    // MARK: - Force Discharge

    public func getForceDischarging()
        throws -> Bool
    {
        guard
            capabilities
                .forceDischargeControl
        else {
            throw
                SMCBatteryError
                .unsupportedCapability
        }

        if hasCHIE {

            let data =
                try SMCKit.shared
                    .readData("CHIE")

            return data.first == 0x08
        }

        let value: UInt8 =
            try SMCKit.shared
                .read("CH0I")

        return value != 0
    }

    public func setForceDischarging(
        _ enabled: Bool
    ) throws {

        guard
            capabilities
                .forceDischargeControl
        else {
            throw
                SMCBatteryError
                .unsupportedCapability
        }

        /*
         To enter force-discharge mode,
         first restore the normal charging gate.

         Then isolate external power.
         */
        if enabled {

            if capabilities.inhibitChargeControl {
                try setChargingInhibited(false)
            }

            if hasCHIE {

                try SMCKit.shared
                    .writeData(
                        "CHIE",
                        Data([0x08])
                    )

            } else {

                try SMCKit.shared
                    .write(
                        "CH0I",
                        UInt8(1)
                    )
            }

        } else {

            try clearForceDischargeKeys()
        }

        // Verify
        for attempt in 1...3 {

            if try getForceDischarging()
                == enabled
            {
                return
            }

            if attempt < 3 {
                Thread.sleep(
                    forTimeInterval:
                        0.05
                )
            }

            if enabled {

                if hasCHIE {

                    try SMCKit.shared
                        .writeData(
                            "CHIE",
                            Data([0x08])
                        )

                } else {

                    try SMCKit.shared
                        .write(
                            "CH0I",
                            UInt8(1)
                        )
                }

            } else {

                try clearForceDischargeKeys()
            }
        }

        throw
            SMCBatteryError
            .verificationFailed(
                feature:
                    "Force discharge",

                expected:
                    enabled
                    ? "enabled"
                    : "disabled",

                actual:
                    (try getForceDischarging())
                    ? "enabled"
                    : "disabled"
            )
    }

    private func clearForceDischargeKeys()
        throws
    {
        if hasCHIE {

            try SMCKit.shared
                .writeData(
                    "CHIE",
                    Data([0x00])
                )

        } else if hasCH0I {

            try SMCKit.shared
                .write(
                    "CH0I",
                    UInt8(0)
                )
        }
    }
}
