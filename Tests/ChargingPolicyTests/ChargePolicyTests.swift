import XCTest
@testable import smc_power

final class ChargePolicyTests: XCTestCase {
    func testNativeResetOccursOncePerTargetNotOnRetries() {
        var policy = NativeLimitResetPolicy()
        XCTAssertTrue(policy.beginRequest(target: 75))
        for _ in 0..<20 { XCTAssertFalse(policy.beginRequest(target: 75)) }
        XCTAssertTrue(policy.beginRequest(target: 50))
        XCTAssertFalse(policy.beginRequest(target: 50))
        XCTAssertFalse(policy.beginRequest(target: 100))
        XCTAssertFalse(policy.beginRequest(target: 100))
        XCTAssertTrue(policy.beginRequest(target: 75))
        XCTAssertFalse(policy.beginRequest(target: 49))
        XCTAssertFalse(policy.beginRequest(target: 75))
    }

    private func plan(_ percentage: Int, _ limit: Int = 65,
                      auto: Bool = true, topUp: Bool = false,
                      ac: Bool = true, gate: Bool = false) -> ChargePolicyPlan {
        ChargePolicy.plan(
            percentage: percentage, normalLimit: limit,
            topUpActive: topUp, adapterConnected: ac,
            automaticDischargeEnabled: auto,
            chargingGateSupported: gate, forceDischargeSupported: true
        )
    }

    func testAutomaticDischargeAndNativeHold() {
        let above = plan(68)
        XCTAssertEqual(above.nativeLimit, 65)
        XCTAssertTrue(above.forceDischargeCommand)
        XCTAssertNil(above.chargingGateCommand)
        let atTarget = plan(65)
        XCTAssertFalse(atTarget.forceDischargeCommand)
        XCTAssertEqual(atTarget.nativeLimit, 65)
    }

    func testRaisingLimitStopsDischarge() {
        let raised = plan(65, 80)
        XCTAssertEqual(raised.nativeLimit, 80)
        XCTAssertFalse(raised.forceDischargeCommand)
    }

    func testAutomaticDischargeOff() {
        let passive = plan(68, auto: false)
        XCTAssertFalse(passive.forceDischargeCommand)
        XCTAssertEqual(passive.nativeLimit, 68, "Native Hold must not itself drain to the lower saved limit")
        XCTAssertEqual(plan(67, auto: false).nativeLimit, 67)
        XCTAssertEqual(plan(65, auto: false).nativeLimit, 65)
        XCTAssertEqual(plan(68, auto: false, ac: false).nativeLimit, 65)
        XCTAssertEqual(plan(68, auto: false, gate: true).nativeLimit, 65)
    }

    func testTopUpPersistsUntilUnplugPolicy() {
        XCTAssertEqual(plan(75, topUp: true).nativeLimit, 100)
        let unplugged = plan(75, topUp: true, ac: false)
        XCTAssertEqual(unplugged.nativeLimit, 65)
        XCTAssertFalse(unplugged.forceDischargeCommand)
    }

    func testUnsupportedGateDoesNotBlockDischarge() {
        let m4 = plan(68)
        XCTAssertNil(m4.chargingGateCommand)
        XCTAssertTrue(m4.forceDischargeCommand)
    }

    func testUnsupportedForceDischargeDoesNotStartProcess() {
        let unsupported = ChargePolicy.plan(
            percentage: 68, normalLimit: 65, topUpActive: false,
            adapterConnected: true, automaticDischargeEnabled: true,
            chargingGateSupported: true, forceDischargeSupported: false
        )
        XCTAssertFalse(unsupported.shouldDischarge)
        XCTAssertFalse(unsupported.forceDischargeCommand)
    }

    func testStaleRevisionCannotProceed() {
        XCTAssertFalse(ChargePolicy.isCurrent(1, current: 2))
        XCTAssertTrue(ChargePolicy.isCurrent(2, current: 2))
    }
}
