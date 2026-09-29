import XCTest
@testable import StasisExecutable

@MainActor
final class PowerPresentationTests: XCTestCase {
    func testPowerPollingCadenceKeepsActiveControlResponsive() {
        XCTAssertEqual(PowerPollingCadence.interval(fast: true, adapterConnected: true,
            isCharging: false, batteryPower: 0), .milliseconds(500))
        XCTAssertEqual(PowerPollingCadence.interval(fast: false, adapterConnected: true,
            isCharging: true, batteryPower: 0), .seconds(2))
        XCTAssertEqual(PowerPollingCadence.interval(fast: false, adapterConnected: true,
            isCharging: false, batteryPower: -20), .seconds(2))
    }

    func testPowerPollingCadenceRestsWhenHoldingOrUnplugged() {
        XCTAssertEqual(PowerPollingCadence.interval(fast: false, adapterConnected: true,
            isCharging: false, batteryPower: 0), .seconds(10))
        XCTAssertEqual(PowerPollingCadence.interval(fast: false, adapterConnected: false,
            isCharging: false, batteryPower: -20), .seconds(10))
    }

    func testHelperRefreshRequiresKnownUnpluggedStateAndNewBuild() {
        XCTAssertTrue(ChargingHelperRefreshPolicy.shouldRefresh(
            manageCharging: true, hasObservedPowerSource: true, adapterConnected: false,
            registeredBuild: "2026092803", currentBuild: "2026092901"))
        XCTAssertFalse(ChargingHelperRefreshPolicy.shouldRefresh(
            manageCharging: true, hasObservedPowerSource: true, adapterConnected: true,
            registeredBuild: "2026092803", currentBuild: "2026092901"))
        XCTAssertFalse(ChargingHelperRefreshPolicy.shouldRefresh(
            manageCharging: true, hasObservedPowerSource: false, adapterConnected: false,
            registeredBuild: "2026092803", currentBuild: "2026092901"))
        XCTAssertFalse(ChargingHelperRefreshPolicy.shouldRefresh(
            manageCharging: true, hasObservedPowerSource: true, adapterConnected: false,
            registeredBuild: "2026092901", currentBuild: "2026092901"))
    }
    func testAdapterSpecificationUsesSelectedPDContractNotLivePower() {
        XCTAssertEqual(AdapterPowerSpecification.watts(details: ["Watts": 140, "AdapterVoltage": 28000, "Current": 4990]), 140)
        XCTAssertEqual(AdapterPowerSpecification.watts(details: ["Watts": 140, "AdapterVoltage": 20000, "Current": 5000]), 100)
        XCTAssertEqual(AdapterPowerSpecification.watts(details: ["Watts": 65, "AdapterVoltage": 20000, "Current": 3250]), 65)
        XCTAssertEqual(AdapterPowerSpecification.watts(details: ["Watts": 96]), 96)
        XCTAssertEqual(AdapterPowerSpecification.watts(details: nil, rawDetails: [["Watts": 30]]), 30)
        XCTAssertNil(AdapterPowerSpecification.watts(details: nil))
        XCTAssertNil(AdapterPowerSpecification.watts(details: ["Watts": 0]))
        XCTAssertNil(AdapterPowerSpecification.watts(details: nil, rawDetails: [["Watts": 60], ["Watts": 140]]))
    }

    private let epoch = Date(timeIntervalSince1970: 1_000)

    private func sample(_ estimator: inout UnpluggedRuntimeEstimator, at second: Double = 0,
                        capacity: Double? = 6_000, full: Double? = 8_000,
                        percentage: Int = 75, voltage: Double = 12, watts: Double = 30) {
        let date = epoch.addingTimeInterval(second)
        estimator.update(remainingCapacityMAh: capacity, fullCapacityMAh: full,
                         actualPercentage: percentage, batteryVoltage: voltage,
                         systemPower: watts, sampleDate: date, now: date)
    }

    func testFirstValidSampleDoesNotWaitForFiveSamples() {
        var estimator = UnpluggedRuntimeEstimator()
        sample(&estimator)
        XCTAssertEqual(estimator.minutes, 145)
        XCTAssertFalse(estimator.isUsingPreviousReading)
    }

    func testColdStartDoesNotTurnTransientThreeWattReadingIntoDayLongEstimate() {
        var estimator = UnpluggedRuntimeEstimator()
        sample(&estimator, watts: 3)
        XCTAssertNil(estimator.minutes)
        sample(&estimator, at: 30, watts: 3)
        XCTAssertNil(estimator.minutes)
        sample(&estimator, at: 32, watts: 30)
        XCTAssertEqual(estimator.minutes, 145)
    }

    func testWakeRetainsEstimateUntilRepresentativePowerReadingReturns() {
        var estimator = UnpluggedRuntimeEstimator()
        sample(&estimator, watts: 30)
        estimator.noteWake(now: epoch.addingTimeInterval(600))
        sample(&estimator, at: 600, watts: 3)
        sample(&estimator, at: 665, watts: 3)
        XCTAssertEqual(estimator.minutes, 145)
        XCTAssertTrue(estimator.isUsingPreviousReading)
        sample(&estimator, at: 670, watts: 50)
        XCTAssertEqual(estimator.minutes, 85)
        XCTAssertFalse(estimator.isUsingPreviousReading)
    }

    func testChangingPowerRouteDoesNotChangeStoredEnergyOrClearEstimate() {
        var estimator = UnpluggedRuntimeEstimator()
        let battery = BatteryMetrics(batteryPower: 0, externalConnected: true)
        let hold = PowerFlowSnapshot.resolve(battery: battery,
            adapter: AdapterMetrics(adapterConnected: true, adapterPower: 30))
        sample(&estimator, watts: hold.systemPower)
        let discharge = PowerFlowSnapshot.resolve(
            battery: BatteryMetrics(batteryPower: -30, externalConnected: false),
            adapter: AdapterMetrics(adapterConnected: true, adapterPower: 30))
        sample(&estimator, at: 1, watts: discharge.systemPower)
        XCTAssertEqual(estimator.minutes, 145)
        let charging = PowerFlowSnapshot.resolve(
            battery: BatteryMetrics(batteryPower: 20, externalConnected: true),
            adapter: AdapterMetrics(adapterConnected: true, adapterPower: 0))
        sample(&estimator, at: 2, capacity: nil, full: nil, voltage: 0, watts: charging.systemPower)
        XCTAssertEqual(estimator.minutes, 145)
        sample(&estimator, at: 3, capacity: 6_000, watts: 30)
        XCTAssertEqual(estimator.minutes, 145)
    }

    func testActualCapacityLossReducesRuntime() {
        var estimator = UnpluggedRuntimeEstimator()
        sample(&estimator)
        sample(&estimator, at: 301, capacity: 4_000, percentage: 50)
        XCTAssertEqual(estimator.minutes, 95)
    }

    func testInvalidCapacityAndVoltageRetainLastValidInputs() {
        var estimator = UnpluggedRuntimeEstimator()
        sample(&estimator)
        sample(&estimator, at: 301, capacity: .nan, full: .infinity, percentage: 50, voltage: .nan, watts: 30)
        XCTAssertEqual(estimator.minutes, 95)
    }

    func testMissingRawCapacityUsesCachedMaximumAndRealPercentage() {
        var estimator = UnpluggedRuntimeEstimator()
        sample(&estimator)
        sample(&estimator, at: 301, capacity: nil, full: nil, percentage: 50)
        XCTAssertEqual(estimator.minutes, 95)
    }

    func testLowCapacityIsNotRejectedAndEmptyBatteryIsZero() {
        var estimator = UnpluggedRuntimeEstimator()
        sample(&estimator, capacity: 250, percentage: 3)
        XCTAssertEqual(estimator.minutes, 5)
        sample(&estimator, at: 1, capacity: 0, percentage: 0)
        XCTAssertEqual(estimator.minutes, 0)
    }

    func testSubminutePowerSpikesDoNotChangeDisplayedRuntime() {
        var estimator = UnpluggedRuntimeEstimator()
        sample(&estimator, watts: 30)
        for second in 1...59 {
            sample(&estimator, at: Double(second), watts: second % 2 == 0 ? 90 : 10)
        }
        XCTAssertEqual(estimator.minutes, 145)
    }

    func testSustainedLoadChangeEventuallyUpdatesButSmallNoiseDoesNot() {
        var stable = UnpluggedRuntimeEstimator()
        sample(&stable, watts: 30)
        for second in 1...600 {
            sample(&stable, at: Double(second), watts: second % 2 == 0 ? 31 : 29)
        }
        XCTAssertEqual(stable.minutes, 145)
        var changed = UnpluggedRuntimeEstimator()
        sample(&changed, watts: 30)
        for second in 1...600 { sample(&changed, at: Double(second), watts: 60) }
        XCTAssertLessThan(changed.minutes ?? 999, 90)
    }

    func testSameSampleIsNotCountedAgainWhenViewRefreshes() {
        var estimator = UnpluggedRuntimeEstimator()
        sample(&estimator, watts: 30)
        for _ in 0..<10 { sample(&estimator, watts: 100) }
        sample(&estimator, at: 61, watts: 30)
        XCTAssertEqual(estimator.minutes, 145)
    }

    func testInvalidPowerDoesNotPoisonAverageAndIsMarkedStale() {
        var estimator = UnpluggedRuntimeEstimator()
        sample(&estimator)
        sample(&estimator, at: 1, watts: .nan)
        sample(&estimator, at: 2, watts: .infinity)
        sample(&estimator, at: 20, watts: 0)
        XCTAssertEqual(estimator.minutes, 145)
        XCTAssertTrue(estimator.isUsingPreviousReading)
        sample(&estimator, at: 21, watts: 30)
        XCTAssertFalse(estimator.isUsingPreviousReading)
    }

    func testWakeAdoptsNewPowerWithoutClearingEnergyCache() {
        var estimator = UnpluggedRuntimeEstimator()
        sample(&estimator, watts: 10)
        sample(&estimator, at: 600, capacity: nil, full: nil, voltage: 0, watts: 30)
        XCTAssertEqual(estimator.minutes, 145)
        XCTAssertTrue(estimator.isUsingPreviousReading)
    }

    func testNoMeasurementsDoesNotInventRuntime() {
        var estimator = UnpluggedRuntimeEstimator()
        sample(&estimator, capacity: nil, full: nil, voltage: 0, watts: 0)
        XCTAssertNil(estimator.minutes)
    }

    func testMixedAdapterAndBatteryPowerIsNotReportedAsBatteryOnly() {
        let flow = PowerFlowSnapshot.resolve(
            battery: BatteryMetrics(batteryPower: -10, externalConnected: true),
            adapter: AdapterMetrics(adapterConnected: true, adapterPower: 20))
        XCTAssertEqual(flow.powerSource, .both)
        XCTAssertEqual(flow.systemPower, 30)
        XCTAssertEqual(flow.chargingMode, .discharging)
    }

    func testSmallNegativeBatteryPowerWhilePluggedInIsHoldNotDischarge() {
        for watts in [-0.4, -1.0, -1.9] {
            let flow = PowerFlowSnapshot.resolve(
                battery: BatteryMetrics(batteryPower: watts, externalConnected: true),
                adapter: AdapterMetrics(adapterConnected: true, adapterPower: 30))
            XCTAssertEqual(flow.powerSource, .acAdapter)
            XCTAssertEqual(flow.chargingMode, .pluggedIn)
            XCTAssertEqual(flow.batteryPower, 0)
            XCTAssertEqual(flow.systemPower, 30)
        }
    }

    func testSubstantialBatteryContributionAlongsideLowWattageAdapter() {
        let flow = PowerFlowSnapshot.resolve(
            battery: BatteryMetrics(batteryPower: -20, externalConnected: true),
            adapter: AdapterMetrics(adapterConnected: true, adapterPower: 30))
        XCTAssertEqual(flow.powerSource, .both)
        XCTAssertEqual(flow.batteryPower, -20)
        XCTAssertEqual(flow.adapterPower, 30)
        XCTAssertEqual(flow.systemPower, 50)
    }

    func testUnplugIgnoresStaleAdapterAndChargingSample() {
        let flow = PowerFlowSnapshot.resolve(
            battery: BatteryMetrics(batteryPower: 20),
            adapter: AdapterMetrics(adapterConnected: false, adapterPower: 60))
        XCTAssertEqual(flow.powerSource, .battery)
        XCTAssertEqual(flow.adapterPower, 0)
        XCTAssertEqual(flow.batteryPower, 0)
        XCTAssertEqual(flow.chargingMode, .discharging)
    }

    func testDragOnlyCommitsAtReleaseAndCancelDoesNotCommit() {
        var draft = ChargeLimitDraft()
        draft.begin(current: 75)
        XCTAssertNil(draft.update(80))
        XCTAssertNil(draft.update(50))
        XCTAssertEqual(draft.finish(enabled: true), 50)
        XCTAssertNil(draft.finish(enabled: true))
        draft.begin(current: 50)
        XCTAssertNil(draft.update(100))
        XCTAssertNil(draft.finish(enabled: false))
        draft.begin(current: 75)
        draft.cancel()
        XCTAssertNil(draft.finish(enabled: true))
    }

    func testKeyboardChangesCommitWithoutPointerDrag() {
        var draft = ChargeLimitDraft()
        XCTAssertEqual(draft.update(76), 76)
        XCTAssertEqual(draft.update(120), 100)
        XCTAssertNil(draft.update(.nan))
    }
    func test100TargetImmediatelySelectsChargingEstimateBeforeCurrentReverses() {
        XCTAssertEqual(TimeEstimateKind.resolve(
            chargingMode: .discharging, adapterConnected: true,
            actualPercentage: 75, effectiveTarget: 100, manageCharging: true,
            calibrationDischarging: false, forceDischarging: false), .charge(target: 100))
    }

    func testLowerTargetKeepsRuntimeEvenWhileOldChargingSampleIsPresent() {
        XCTAssertEqual(TimeEstimateKind.resolve(
            chargingMode: .charging, adapterConnected: true,
            actualPercentage: 75, effectiveTarget: 50, manageCharging: true,
            calibrationDischarging: false, forceDischarging: false), .runtime)
    }

    func testUnpluggedDoesNotShowTimeToCharge() {
        XCTAssertEqual(TimeEstimateKind.resolve(
            chargingMode: .discharging, adapterConnected: false,
            actualPercentage: 75, effectiveTarget: 100, manageCharging: true,
            calibrationDischarging: false, forceDischarging: false), .runtime)
    }

    func testChargeEstimateAvailableOnFirstValidCurrentAndImmediatelyChangesTarget() {
        var estimator = ChargeTimeEstimator()
        var metrics = BatteryMetrics(hardwareBatteryPercentage: 75,
            remainingCapacityMAh: 6_000, fullCapacityMAh: 8_000,
            batteryVoltage: 12, batteryCurrent: 2, batteryPower: 24)
        estimator.update(metrics: metrics, target: 100, sampleDate: epoch, now: epoch)
        XCTAssertEqual(estimator.minutes, 60)
        estimator.update(metrics: metrics, target: 80, sampleDate: epoch, now: epoch)
        XCTAssertEqual(estimator.minutes, 12)
        metrics.batteryCurrent = 0
        metrics.batteryPower = 0
        estimator.update(metrics: metrics, target: 100,
                         sampleDate: epoch.addingTimeInterval(2), now: epoch.addingTimeInterval(2))
        XCTAssertEqual(estimator.minutes, 60)
    }

    func testUnknownChargingRateNeverReusesDischargeTimeAsTimeToFull() {
        var estimator = ChargeTimeEstimator()
        var metrics = BatteryMetrics(hardwareBatteryPercentage: 75, timeRemaining: 129,
            remainingCapacityMAh: 6_000, fullCapacityMAh: 8_000)
        estimator.update(metrics: metrics, target: 100, sampleDate: epoch, now: epoch)
        XCTAssertNil(estimator.minutes)
        metrics.timeToFullMinutes = 45
        estimator.update(metrics: metrics, target: 100, sampleDate: epoch, now: epoch)
        XCTAssertEqual(estimator.minutes, 45)
    }

    func testRuntimeDoesNotChangeDuringFirstFiveMinutesEvenWithSustainedLoad() {
        var estimator = UnpluggedRuntimeEstimator()
        sample(&estimator, watts: 30)
        for second in 1...299 {
            sample(&estimator, at: Double(second), watts: 90)
            XCTAssertEqual(estimator.minutes, 145)
        }
        sample(&estimator, at: 300, watts: 90)
        XCTAssertLessThan(estimator.minutes ?? 999, 60)
    }

    func testSystemTimeToFullWorksWithoutRawCapacityAndNeverLeaksToLowerGoal() {
        var estimator = ChargeTimeEstimator()
        let metrics = BatteryMetrics(hardwareBatteryPercentage: 75, timeToFullMinutes: 47)
        estimator.update(metrics: metrics, target: 100, sampleDate: epoch, now: epoch)
        XCTAssertEqual(estimator.minutes, 47)
        estimator.update(metrics: metrics, target: 80, sampleDate: epoch, now: epoch)
        XCTAssertNil(estimator.minutes)
    }

    func testRecentChargingRateSurvivesHoldAndImmediatelyRecomputes100Target() {
        var estimator = ChargeTimeEstimator()
        var metrics = BatteryMetrics(hardwareBatteryPercentage: 75,
            remainingCapacityMAh: 6_000, fullCapacityMAh: 8_000,
            batteryVoltage: 12, batteryCurrent: 2, batteryPower: 24)
        estimator.update(metrics: metrics, target: 80, sampleDate: epoch, now: epoch)
        metrics.batteryCurrent = 0
        metrics.batteryPower = 0
        let date = epoch.addingTimeInterval(60)
        estimator.update(metrics: metrics, target: 75, sampleDate: date, now: date)
        XCTAssertEqual(estimator.minutes, 0)
        estimator.update(metrics: metrics, target: 100, sampleDate: date, now: date)
        XCTAssertEqual(estimator.minutes, 60)
    }

    func testChargingRampCorrectsInitialTrickleEstimateThenSettles() {
        var estimator = ChargeTimeEstimator()
        var metrics = BatteryMetrics(hardwareBatteryPercentage: 75,
            remainingCapacityMAh: 6_000, fullCapacityMAh: 8_000,
            batteryVoltage: 12, batteryCurrent: 0.8, batteryPower: 9.6)
        estimator.update(metrics: metrics, target: 100, sampleDate: epoch, now: epoch)
        XCTAssertEqual(estimator.minutes, 150)
        for second in 1...10 {
            metrics.batteryCurrent = min(5, 0.8 + Double(second))
            metrics.batteryPower = metrics.batteryCurrent * 12
            let date = epoch.addingTimeInterval(Double(second))
            estimator.update(metrics: metrics, target: 100, sampleDate: date, now: date)
            if second == 4 { XCTAssertEqual(estimator.minutes, 150) }
            if second == 5 { XCTAssertLessThan(estimator.minutes ?? 999, 40) }
        }
        XCTAssertLessThan(estimator.minutes ?? 999, 30)
        let settled = estimator.minutes
        for second in 11...39 {
            metrics.batteryCurrent = second % 2 == 0 ? 3 : 5
            metrics.batteryPower = metrics.batteryCurrent * 12
            let date = epoch.addingTimeInterval(Double(second))
            estimator.update(metrics: metrics, target: 100, sampleDate: date, now: date)
            XCTAssertEqual(estimator.minutes, settled, "After startup, retain the low-frequency ETA")
        }
    }

}
