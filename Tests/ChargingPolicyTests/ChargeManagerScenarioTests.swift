import Defaults
import XCTest
@testable import StasisExecutable
@testable import smc_power

@MainActor
final class ChargeManagerScenarioTests: XCTestCase {
    private final class Battery: BatteryService {
        var externalPower: [Bool] = []
        var charging: [Bool] = []
        var suspendDischarge = false
        var pendingDischarge: CheckedContinuation<Void, Never>?
        var failNextCommand = false

        override func manageExternalPower(enabled: Bool) async throws {
            if !enabled && suspendDischarge {
                await withCheckedContinuation { pendingDischarge = $0 }
            }
            externalPower.append(enabled)
            if failNextCommand {
                failNextCommand = false
                throw XPCError.timedOut
            }
        }
        override func manageBatteryCharging(enabled: Bool) async throws {
            charging.append(enabled)
        }
        override func manageMagsafeLED(target: MagSafeLEDState) async throws {}
        override func scheduleTransitionPolls() {}
        override func scheduleSinglePoll(delay: Duration = .milliseconds(150)) {}
    }

    @MainActor private final class Harness {
        let battery: Battery
        let coordinator: NativeChargeLimitCoordinator
        let manager: ChargeManager
        var state: BatteryControlState { battery.controlState }
        let native: Native
        @MainActor final class Native {
            var actual = NativeChargeLimitCoordinator.SystemNativeChargeLimitState(enabled: false, limit: nil)
            var requests: [Int] = []
            var acceptWrites = true
            var readCount = 0
        }

        init(gate: Bool, force: Bool, nativeAvailable: Bool) {
            let native = Native()
            self.native = native
            battery = Battery(testState: .init(
                batteryPercentage: 75, hardwareBatteryPercentage: 75,
                adapterConnected: true, batteryTemperature: 33
            ), capabilities: .init(
                chargingControl: gate, adapterControl: force,
                hasMagSafe: false, magsafeLEDControl: false
            ))
            coordinator = NativeChargeLimitCoordinator(operations: .init(
                isAvailable: { nativeAvailable }, enable: {},
                disable: { native.actual = .init(enabled: false, limit: nil) },
                applyLimit: { limit in
                    native.requests.append(limit)
                    if native.acceptWrites {
                        native.actual = .init(enabled: limit != 100, limit: limit == 100 ? nil : limit)
                    }
                },
                readSystemState: { native.readCount += 1; return native.actual }, refreshMetrics: {}
            ))
            manager = ChargeManager(
                batteryService: battery, nativeCoordinator: coordinator,
                startObserving: false, sleepAssertionHandler: { _ in }, record: { _, _ in }
            )
        }
        func evaluate(_ update: (inout BatteryControlState) -> Void = { _ in }) {
            var next = state
            update(&next)
            battery.setTestState(next)
            manager.evaluate(controlState: next)
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(160)) }
        func expect(_ limit: Int?, external: Bool, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(native.actual.limit, limit == 100 ? nil : limit, file: file, line: line)
            XCTAssertEqual(battery.externalPower.last, external, file: file, line: line)
        }
    }

    private func run(gate: Bool = false, force: Bool = true, native: Bool = true,
                     _ body: (Harness) async throws -> Void) async throws {
        let names = ["manageCharging", "chargeLimit", "automaticDischarge", "topUpSessionActive",
                     "topUpLastAdapterConnected", "calibrationPhase", "calibrationOriginalLimit",
                     "calibrationHoldStartedAt", "lastCalibrationDate", "lastCalibrationAttemptDate",
                     "automaticMonthlyCalibration", "useHardwarePercentage", "enableHeatProtectionMode",
                     "heatProtectionLimit", "sailingMode", "sailingModeLimit", "manageMagSafeLED",
                     "disableSleepUntilChargeLimit", "disableNotifications"]
        let saved = names.map { UserDefaults.standard.object(forKey: $0) }
        Defaults[.manageCharging] = true
        Defaults[.chargeLimit] = 75
        Defaults[.automaticDischarge] = true
        Defaults[.topUpSessionActive] = false
        Defaults[.calibrationPhase] = .idle
        Defaults[.automaticMonthlyCalibration] = false
        Defaults[.useHardwarePercentage] = false
        Defaults[.enableHeatProtectionMode] = true
        Defaults[.heatProtectionLimit] = 40
        Defaults[.sailingMode] = true
        Defaults[.sailingModeLimit] = 5
        Defaults[.manageMagSafeLED] = false
        Defaults[.disableSleepUntilChargeLimit] = false
        Defaults[.disableNotifications] = true
        let h = Harness(gate: gate, force: force, nativeAvailable: native)
        defer {
            h.battery.pendingDischarge?.resume()
            h.manager.stop()
            for (key, value) in zip(names, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        try await body(h)
    }

    func testEverySliderLimitThroughActualManager() async throws {
        try await run { h in
            for target in 50...100 {
                Defaults[.chargeLimit] = target
                h.evaluate()
                try await h.settle()
                h.expect(target, external: target >= 75)
                XCTAssertTrue(h.battery.charging.isEmpty, "Unsupported gate must never be called")
            }
        }
    }

    func testAutoOffHoldsThenEnableDischargesAndRaisingStops() async throws {
        try await run { h in
            Defaults[.chargeLimit] = 65
            Defaults[.automaticDischarge] = false
            h.evaluate(); try await h.settle(); h.expect(75, external: true)
            Defaults[.automaticDischarge] = true
            h.evaluate(); try await h.settle(); h.expect(65, external: false)
            Defaults[.chargeLimit] = 80
            h.evaluate(); try await h.settle(); h.expect(80, external: true)
            Defaults[.chargeLimit] = 65
            h.evaluate(); try await h.settle(); h.expect(65, external: false)
            h.evaluate { $0.batteryPercentage = 65; $0.hardwareBatteryPercentage = 65 }
            try await h.settle(); h.expect(65, external: true)
        }
    }

    func testRapidRaiseThenReturnToCurrentLevelCatchesOvershoot() async throws {
        try await run { h in

            // 初始：
            // Battery = 75
            // Limit = 75
            h.evaluate()
            try await h.settle()
            h.expect(75, external: true)

            // 75 -> 70
            // 应立即主动放电。
            Defaults[.chargeLimit] = 70
            h.evaluate()
            try await h.settle()
            h.expect(70, external: false)

            // 快速 70 -> 80
            // 应立即退出 CHIE 并恢复充电。
            Defaults[.chargeLimit] = 80
            h.evaluate()
            try await h.settle()
            h.expect(80, external: true)

            // 紧接着 80 -> 75。
            //
            // 此刻真实电量仍然正好是 75，
            // 所以不能立即主动放电。
            Defaults[.chargeLimit] = 75
            h.evaluate()
            try await h.settle()
            h.expect(75, external: true)

            // 模拟 macOS 仍短暂沿用旧 80% MCL：
            // 电量从 75 反冲到 76。
            //
            // Stasis 必须立即重新武装 Automatic Discharge，
            // 不能继续充到 77 / 78。
            h.evaluate {
                $0.batteryPercentage = 76
                $0.hardwareBatteryPercentage = 76
            }

            try await h.settle()
            h.expect(75, external: false)

            // 回到目标以后必须立即退出 CHIE，
            // 恢复 AC + Native Hold。
            h.evaluate {
                $0.batteryPercentage = 75
                $0.hardwareBatteryPercentage = 75
            }

            try await h.settle()
            h.expect(75, external: true)
        }
    }

    func testUnsupportedHeatProtectionCannotBlockDischarge() async throws {
        try await run { h in
            Defaults[.chargeLimit] = 65
            h.evaluate { $0.batteryTemperature = 45 }
            try await h.settle(); h.expect(65, external: false)
        }
    }

    func testPercentageSourceChangeReevaluatesDischarge() async throws {
        try await run { h in
            h.evaluate { $0.hardwareBatteryPercentage = 78 }
            try await h.settle(); h.expect(75, external: true)
            Defaults[.useHardwarePercentage] = true
            h.evaluate(); try await h.settle(); h.expect(75, external: false)
            Defaults[.useHardwarePercentage] = false
            h.evaluate(); try await h.settle(); h.expect(75, external: true)
        }
    }

    func testTopUpCancelAndPhysicalUnplug() async throws {
        try await run { h in
            h.evaluate(); try await h.settle()
            h.manager.toggleChargeLimitOverride()
            try await h.settle(); h.expect(100, external: true)
            XCTAssertTrue(Defaults[.topUpSessionActive])
            h.manager.toggleChargeLimitOverride()
            try await h.settle(); h.expect(75, external: true)
            h.manager.toggleChargeLimitOverride()
            try await h.settle()
            h.evaluate { $0.adapterConnected = false }
            try await h.settle(); h.expect(100, external: true)
            XCTAssertFalse(Defaults[.topUpSessionActive])
            XCTAssertEqual(h.manager.effectiveChargeLimit, 75, "The saved limit is restored without off-AC writes")
            h.evaluate { $0.adapterConnected = true }
            try await h.settle(); h.expect(75, external: true)
        }
    }

    func testTopUpSessionSurvivesManagerRecreation() async throws {
        try await run { h in
            h.manager.toggleChargeLimitOverride()
            try await h.settle()
            h.manager.stop()
            let replacement = Harness(gate: false, force: true, nativeAvailable: true)
            defer { replacement.manager.stop() }
            replacement.evaluate()
            try await replacement.settle()
            replacement.expect(100, external: true)
            replacement.evaluate { $0.adapterConnected = false }
            try await replacement.settle()
            replacement.expect(100, external: true)
            XCTAssertFalse(Defaults[.topUpSessionActive])
            replacement.evaluate { $0.adapterConnected = true }
            try await replacement.settle()
            replacement.expect(75, external: true)
        }
    }

    func testDisableDuringDischargeAndReenable() async throws {
        try await run { h in
            Defaults[.chargeLimit] = 65
            h.evaluate(); try await h.settle(); h.expect(65, external: false)
            Defaults[.manageCharging] = false
            h.evaluate(); try await h.settle(); h.expect(nil, external: true)
            Defaults[.manageCharging] = true
            h.evaluate(); try await h.settle(); h.expect(65, external: false)
        }
    }

    func testHelperRemovalRestoresACAndClearsCalibration() async throws {
        try await run { h in
            h.manager.startCalibration()
            h.evaluate { $0.batteryPercentage = 100 }
            try await h.settle(); h.expect(100, external: false)
            try await h.manager.prepareForHelperRemoval()
            try await h.settle(); h.expect(nil, external: true)
            XCTAssertEqual(Defaults[.calibrationPhase], .idle)
        }
    }

    func testCalibrationAllPhaseBoundariesAndCancel() async throws {
        try await run { h in
            h.manager.startCalibration()
            try await h.settle(); h.expect(100, external: true)
            h.evaluate { $0.batteryPercentage = 100 }
            try await h.settle(); h.expect(100, external: false)
            XCTAssertEqual(Defaults[.calibrationPhase], .dischargingToTen)
            h.evaluate { $0.batteryPercentage = 10 }
            try await h.settle(); h.expect(100, external: true)
            XCTAssertEqual(Defaults[.calibrationPhase], .chargingToFullAgain)
            h.evaluate { $0.batteryPercentage = 100 }
            try await h.settle(); h.expect(100, external: true)
            XCTAssertEqual(Defaults[.calibrationPhase], .holdingAtFull)
            Defaults[.calibrationHoldStartedAt] = Date().addingTimeInterval(-3601)
            h.evaluate(); try await h.settle(); h.expect(75, external: false)
            h.evaluate { $0.batteryPercentage = 75 }
            try await h.settle(); h.expect(75, external: true)
            XCTAssertEqual(Defaults[.calibrationPhase], .idle)
            h.manager.startCalibration()
            try await h.settle()
            h.manager.cancelCalibration()
            try await h.settle(); h.expect(75, external: true)
        }
    }

    func testCancellingOverdueMonthlyCalibrationDoesNotRestartImmediately() async throws {
        try await run { h in
            Defaults[.lastCalibrationDate] = Date().addingTimeInterval(-86400 * 40)
            UserDefaults.standard.removeObject(forKey: "lastCalibrationAttemptDate")
            Defaults[.automaticMonthlyCalibration] = true
            h.evaluate(); try await h.settle()
            XCTAssertNotEqual(Defaults[.calibrationPhase], .idle)
            h.manager.cancelCalibration()
            try await h.settle()
            XCTAssertEqual(Defaults[.calibrationPhase], .idle)
            h.expect(75, external: true)
        }
    }

    func testStaleCHIEReplyMustBeFollowedByCorrectiveOff() async throws {
        try await run { h in
            h.battery.suspendDischarge = true
            Defaults[.chargeLimit] = 65
            h.evaluate(); try await h.settle()
            XCTAssertNotNil(h.battery.pendingDischarge)
            Defaults[.chargeLimit] = 80
            h.evaluate()
            h.battery.pendingDischarge?.resume()
            h.battery.pendingDischarge = nil
            try await h.settle(); h.expect(80, external: true)
            XCTAssertEqual(h.battery.externalPower.suffix(2), [false, true])
        }
    }

    func testMeasuredOverchargeStopsWhileNativeLimitIsUnconfirmedThenReleasesAtGoal() async throws {
        try await run { h in
            h.native.actual = .init(enabled: true, limit: 80)
            h.native.acceptWrites = false
            h.battery.setTestPowerSample(watts: 30, current: 2.5)
            h.evaluate { $0.batteryPercentage = 76; $0.hardwareBatteryPercentage = 76 }
            try await Task.sleep(for: .milliseconds(2300))
            XCTAssertTrue(h.battery.externalPower.contains(false), "Fresh continued charging above the limit must not wait until 80")
            XCTAssertEqual(h.native.actual.limit, 80, "The guard must not pretend the native limit is verified")
            h.battery.setTestPowerSample(watts: -20, current: -1.5)
            h.evaluate { $0.batteryPercentage = 75; $0.hardwareBatteryPercentage = 75 }
            try await h.settle()
            XCTAssertEqual(h.battery.externalPower.last, true)
        }
    }

    func testStaleOverchargeTelemetryCannotBypassNativeConfirmation() async throws {
        try await run { h in
            h.native.actual = .init(enabled: true, limit: 80)
            h.native.acceptWrites = false
            h.battery.setTestPowerSample(watts: 30, current: 2.5, date: Date().addingTimeInterval(-60))
            h.evaluate { $0.batteryPercentage = 76; $0.hardwareBatteryPercentage = 76 }
            try await Task.sleep(for: .milliseconds(5300))
            XCTAssertFalse(h.battery.externalPower.contains(false))
        }
    }

    func testTopUpAndSleepCannotUseOverchargeEmergencyPath() async throws {
        try await run { h in
            h.manager.toggleChargeLimitOverride()
            try await h.settle()
            h.battery.setTestPowerSample(watts: 30, current: 2.5)
            h.evaluate { $0.batteryPercentage = 80; $0.hardwareBatteryPercentage = 80 }
            try await h.settle()
            XCTAssertFalse(h.battery.externalPower.contains(false))
            h.native.acceptWrites = false
            h.manager.toggleChargeLimitOverride()
            h.manager.handleWillSleep()
            try await Task.sleep(for: .milliseconds(2300))
            XCTAssertFalse(h.battery.externalPower.contains(false))
        }
    }

    func testUnconfirmedNativeRequestNeverStartsDischarge() async throws {
        try await run { h in
            h.native.actual = .init(enabled: true, limit: 89)
            h.native.acceptWrites = false
            Defaults[.chargeLimit] = 65
            h.evaluate(); try await h.settle()
            XCTAssertFalse(h.battery.externalPower.contains(false))
            Defaults[.chargeLimit] = 90
            h.native.acceptWrites = true
            h.evaluate(); try await h.settle(); h.expect(90, external: true)
        }
    }

    func testTransientCHIEFailureStillCorrectsNewerTarget() async throws {
        try await run { h in
            h.battery.failNextCommand = true
            Defaults[.chargeLimit] = 65
            h.evaluate(); try await h.settle()
            Defaults[.chargeLimit] = 80
            h.evaluate(); try await h.settle(); h.expect(80, external: true)
        }
    }

    func testSleepRestoresACAndWakeReevaluatesDischarge() async throws {
        try await run { h in
            Defaults[.chargeLimit] = 65
            h.evaluate(); try await h.settle(); h.expect(65, external: false)
            h.manager.handleWillSleep()
            try await h.settle(); h.expect(65, external: true)
            h.manager.handleDidWake()
            try await Task.sleep(for: .milliseconds(550))
            h.expect(65, external: false)
        }
    }

    func testOffACSleepAndWakeStayPausedUntilPhysicalReconnect() async throws {
        try await run { h in
            h.evaluate(); try await h.settle()
            h.evaluate { $0.adapterConnected = false }
            try await h.settle()
            let requests = h.native.requests
            let reads = h.native.readCount
            h.native.actual = .init(enabled: false, limit: nil)
            h.manager.handleWillSleep()
            Defaults[.chargeLimit] = 65
            h.evaluate()
            h.manager.handleDidWake()
            try await Task.sleep(for: .milliseconds(1_150))
            XCTAssertTrue(h.coordinator.isSuspended)
            XCTAssertEqual(h.native.requests, requests)
            XCTAssertEqual(h.native.readCount, reads)
            XCTAssertEqual(h.manager.effectiveChargeLimit, 65)
            h.evaluate { $0.adapterConnected = true }
            try await h.settle()
            XCTAssertFalse(h.coordinator.isSuspended)
            h.expect(65, external: false)
        }
    }

    func testSleepStopsUnconfirmedNativePollingWithoutBreakingACRestore() async throws {
        try await run { h in
            h.native.acceptWrites = false
            Defaults[.chargeLimit] = 80
            h.evaluate(); try await h.settle()
            h.manager.handleWillSleep()
            try await h.settle()
            let requests = h.native.requests
            let reads = h.native.readCount
            try await Task.sleep(for: .milliseconds(2_200))
            XCTAssertEqual(h.native.requests, requests)
            XCTAssertEqual(h.native.readCount, reads)
            XCTAssertEqual(h.battery.externalPower.last, true)
            XCTAssertFalse(h.battery.externalPower.contains(false))
            h.native.acceptWrites = true
            h.manager.handleDidWake()
            try await Task.sleep(for: .milliseconds(550))
            h.expect(80, external: true)
        }
    }

    func testDisablingManagementWhileUnpluggedStillClearsNativeHold() async throws {
        try await run { h in
            h.evaluate(); try await h.settle()
            h.evaluate { $0.adapterConnected = false }
            try await h.settle()
            XCTAssertTrue(h.coordinator.isSuspended)
            Defaults[.manageCharging] = false
            h.evaluate(); try await h.settle()
            XCTAssertFalse(h.coordinator.isSuspended)
            h.expect(nil, external: true)
        }
    }

    func testLegacyGateHeatProtectionAndSailing() async throws {
        try await run(gate: true, native: false) { h in
            h.evaluate(); try await h.settle()
            XCTAssertEqual(h.battery.charging.last, false)
            h.evaluate { $0.batteryPercentage = 72 }
            try await h.settle(); XCTAssertEqual(h.battery.charging.last, false)
            h.evaluate { $0.batteryPercentage = 69 }
            try await h.settle(); XCTAssertEqual(h.battery.charging.last, true)
            h.evaluate { $0.batteryTemperature = 45 }
            try await h.settle(); XCTAssertEqual(h.battery.charging.last, false)
            h.evaluate { $0.batteryTemperature = 35 }
            try await h.settle(); XCTAssertEqual(h.battery.charging.last, true)
        }
    }

    func testCalibrationUnavailableWithoutDischargeCapability() async throws {
        try await run(force: false) { h in
            h.manager.startCalibration()
            try await h.settle()
            XCTAssertEqual(Defaults[.calibrationPhase], .idle)
        }
    }
}
