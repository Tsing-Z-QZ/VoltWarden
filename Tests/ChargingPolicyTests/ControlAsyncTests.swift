import XCTest
@testable import StasisExecutable

@MainActor
final class ControlAsyncTests: XCTestCase {
    @MainActor private final class NativeFake {
        var actual: NativeChargeLimitCoordinator.SystemNativeChargeLimitState?
        var requests: [Int] = []
        var pendingApply: CheckedContinuation<Void, Never>?
        var holdApply = false
        var failApply = false
        var readCount = 0
        var disableCount = 0

        func coordinator() -> NativeChargeLimitCoordinator {
            NativeChargeLimitCoordinator(operations: .init(
                isAvailable: { true }, enable: {}, disable: { [self] in disableCount += 1 },
                applyLimit: { [self] limit in
                    requests.append(limit)
                    if failApply { throw XPCError.timedOut }
                    if holdApply {
                        await withCheckedContinuation { pendingApply = $0 }
                    }
                },
                readSystemState: { [self] in readCount += 1; return actual }, refreshMetrics: {}
            ))
        }

        func release() {
            holdApply = false
            pendingApply?.resume()
            pendingApply = nil
        }
    }

    func testRealSystemLimitSucceedsBeforeHelperReplyUpdatesCache() async {
        let fake = NativeFake()
        fake.actual = .init(enabled: true, limit: 65)
        fake.holdApply = true
        let coordinator = fake.coordinator()
        let ready = await coordinator.requestAndWait(enabled: true, limit: 65, timeout: .milliseconds(200))
        XCTAssertTrue(ready, "A verified pmset limit must succeed even while local apply is pending")
        coordinator.stop()
        fake.release()
    }

    func testSystemUnrestrictedChargingSatisfiesTopUp100ButNotLowerTarget() async {
        let fake = NativeFake()
        fake.actual = .init(enabled: false, limit: nil)
        let coordinator = fake.coordinator()
        let full = await coordinator.requestAndWait(enabled: true, limit: 100, timeout: .milliseconds(120))
        XCTAssertTrue(full)
        let lower = await coordinator.requestAndWait(enabled: true, limit: 75, timeout: .milliseconds(120))
        XCTAssertFalse(lower)
        coordinator.stop()
    }

    func testSupersededWaitCannotStartOldDischarge() async throws {
        let fake = NativeFake()
        fake.holdApply = true
        let coordinator = fake.coordinator()
        var startedOldDischarge = false
        let oldPlan = Task {
            if await coordinator.requestAndWait(enabled: true, limit: 65, timeout: .seconds(2)) {
                startedOldDischarge = true
            }
        }
        for _ in 0..<50 where fake.pendingApply == nil {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(fake.requests, [65])
        let clock = ContinuousClock()
        let start = clock.now
        coordinator.request(enabled: true, limit: 80)
        await oldPlan.value
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(300))
        XCTAssertFalse(startedOldDischarge)
        fake.actual = .init(enabled: true, limit: 80)
        fake.release()
        let latestReady = await coordinator.requestAndWait(enabled: true, limit: 80)
        XCTAssertTrue(latestReady)
        coordinator.stop()
    }

    func testExternalPlanRevisionInvalidatesWaitEvenIfLimitUnchanged() async throws {
        let fake = NativeFake()
        let coordinator = fake.coordinator()
        var current = true
        let waiter = Task {
            await coordinator.requestAndWait(enabled: true, limit: 65, timeout: .seconds(2), isCurrent: { current })
        }
        try await Task.sleep(for: .milliseconds(20))
        current = false
        let ready = await waiter.value
        XCTAssertFalse(ready, "Turning auto discharge off must cancel its pending native wait")
        coordinator.stop()
    }

    func testHelperAcknowledgementAloneDoesNotVerifyNativeLimit() async {
        let fake = NativeFake()
        let coordinator = fake.coordinator()
        let ready = await coordinator.requestAndWait(enabled: true, limit: 65, timeout: .milliseconds(120))
        XCTAssertFalse(ready)
        XCTAssertEqual(fake.requests, [65])
        coordinator.stop()
    }

    func testChangedTargetIsAppliedEvenWhenCurrentSnapshotAlreadyMatches() async throws {
        let fake = NativeFake()
        let coordinator = fake.coordinator()
        fake.actual = .init(enabled: true, limit: 70)
        coordinator.request(enabled: true, limit: 70)
        for _ in 0..<50 where fake.requests.last != 70 {
            try await Task.sleep(for: .milliseconds(2))
        }

        // A delayed 70 request may still be queued inside powerd even though a
        // read taken just before the latest request temporarily reports 80.
        fake.actual = .init(enabled: true, limit: 80)
        coordinator.request(enabled: true, limit: 80)
        for _ in 0..<50 where fake.requests.last != 80 {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(fake.requests.suffix(2), [70, 80])
        coordinator.stop()
    }

    func testRapidNativeTargetsCoalesceToFinalValue() async throws {
        let fake = NativeFake()
        fake.actual = .init(enabled: true, limit: 80)
        let coordinator = fake.coordinator()
        coordinator.request(enabled: true, limit: 80)
        for _ in 0..<100 where fake.requests.last != 80 {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(fake.requests, [80])

        fake.requests.removeAll()
        for index in 0..<100 {
            coordinator.request(enabled: true, limit: 70 + index % 20)
        }
        coordinator.request(enabled: true, limit: 83)
        fake.actual = .init(enabled: true, limit: 83)

        for _ in 0..<150 where fake.requests.last != 83 {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(fake.requests, [83], "Only the final slider target should reach the helper")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fake.requests, [83], "No superseded target may arrive after the final apply")
        coordinator.stop()
    }

    func testLateNativeConfirmationAfterAckDoesNotRequireAnotherWrite() async throws {
        let fake = NativeFake()
        fake.actual = .init(enabled: true, limit: 80)
        let coordinator = fake.coordinator()
        defer { coordinator.stop() }
        _ = await coordinator.requestAndWait(enabled: true, limit: 80)
        try await Task.sleep(for: .milliseconds(100))
        fake.requests.removeAll()
        let settle = Task {
            try await Task.sleep(for: .milliseconds(2400))
            fake.actual = .init(enabled: true, limit: 75)
        }
        let ready = await coordinator.requestAndWait(enabled: true, limit: 75, timeout: .seconds(4))
        try await settle.value
        XCTAssertTrue(ready, "Accept actual 75 after the latest ACK, even beyond the short initial verifier")
        XCTAssertEqual(fake.requests, [75], "A late success must not be reset by another privileged write")
    }

    func testChangedTargetRequiresFreshApplyBeforeDischargeCanProceed() async throws {
        let fake = NativeFake()
        fake.actual = .init(enabled: true, limit: 70)
        let coordinator = fake.coordinator()
        coordinator.request(enabled: true, limit: 70)
        for _ in 0..<100 where fake.requests.last != 70 {
            try await Task.sleep(for: .milliseconds(2))
        }

        // Simulate a coincidental/stale powerd snapshot that already says 80
        // while the latest privileged 80 write has not acknowledged yet.
        fake.actual = .init(enabled: true, limit: 80)
        fake.holdApply = true
        let ready = await coordinator.requestAndWait(
            enabled: true,
            limit: 80,
            timeout: .milliseconds(180)
        )
        XCTAssertFalse(ready)
        XCTAssertEqual(fake.requests.last, 80)
        coordinator.stop()
        fake.release()
    }

    func testParserDoesNotMixDictionariesOrAcceptConflictingLimits() {
        let parse = NativeChargeLimitCoordinator.parseSystemState
        XCTAssertNil(parse("{ chargeSocLimitReason = manualChargeLimit; } { chargeSocLimitSoc = 65; }"))
        XCTAssertNil(parse("{ chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 65; } { chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 80; }"))
        XCTAssertEqual(parse("{ chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 75; } { chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 75; }")?.limit, 75)
        XCTAssertEqual(parse("No battery level limits set")?.enabled, false)
        XCTAssertNil(parse("pmset failed"))
    }

    func testSuspensionPreservesHoldAndQueuesOnlyLatestTargetWithoutAudits() async throws {
        let fake = NativeFake()
        fake.actual = .init(enabled: true, limit: 75)
        let coordinator = fake.coordinator()
        defer { coordinator.stop() }
        coordinator.request(enabled: true, limit: 75)
        for _ in 0..<100 where fake.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(fake.requests, [75])
        coordinator.setSuspended(true)
        let readCount = fake.readCount
        for target in [80, 50, 100, 65] { coordinator.request(enabled: true, limit: target) }
        coordinator.invalidateAppliedState()
        try await Task.sleep(for: .milliseconds(1_150))
        XCTAssertEqual(fake.requests, [75])
        XCTAssertEqual(fake.readCount, readCount, "Suspension must cancel delayed verification too")
        XCTAssertEqual(fake.disableCount, 0, "Sleep must not remove the existing system Hold")
        XCTAssertEqual(fake.actual?.limit, 75)

        fake.actual = .init(enabled: true, limit: 65)
        coordinator.setSuspended(false)
        let ready = await coordinator.requestAndWait(enabled: true, limit: 65)
        XCTAssertTrue(ready)
        XCTAssertEqual(fake.requests, [75, 65])
    }

    func testSuspendedWaitDoesNotPollOrClaimReadyFromOldCache() async throws {
        let fake = NativeFake()
        fake.actual = .init(enabled: true, limit: 75)
        let coordinator = fake.coordinator()
        defer { coordinator.stop() }
        coordinator.request(enabled: true, limit: 75)
        try await Task.sleep(for: .milliseconds(20))
        coordinator.setSuspended(true)
        let readCount = fake.readCount
        let clock = ContinuousClock()
        let start = clock.now
        let ready = await coordinator.requestAndWait(enabled: true, limit: 75)
        XCTAssertFalse(ready)
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(200))
        XCTAssertEqual(fake.readCount, readCount)
    }

    func testSleepCancelsScheduledRetryAndResumeCanRetryAgain() async throws {
        let fake = NativeFake()
        fake.failApply = true
        let coordinator = fake.coordinator()
        defer { coordinator.stop() }
        coordinator.request(enabled: true, limit: 75)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.requests, [75])
        coordinator.setSuspended(true)
        let readCount = fake.readCount
        try await Task.sleep(for: .milliseconds(2_200))
        XCTAssertEqual(fake.requests, [75], "The two-second retry must not run during sleep")
        XCTAssertEqual(fake.readCount, readCount)
        fake.failApply = false
        fake.actual = .init(enabled: true, limit: 75)
        coordinator.setSuspended(false)
        for _ in 0..<100 where fake.requests.count < 2 {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(fake.requests, [75, 75])
    }

    func testResumeWaitsForInFlightHelperBeforeApplyingLatestTarget() async throws {
        let fake = NativeFake()
        fake.holdApply = true
        let coordinator = fake.coordinator()
        defer { coordinator.stop(); fake.release() }
        let waiter = Task { await coordinator.requestAndWait(enabled: true, limit: 65) }
        for _ in 0..<100 where fake.pendingApply == nil {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(fake.requests, [65])
        coordinator.setSuspended(true)
        let oldReady = await waiter.value
        XCTAssertFalse(oldReady)
        coordinator.request(enabled: true, limit: 80)
        coordinator.setSuspended(false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fake.requests, [65], "An in-flight privileged write keeps its serial queue slot")
        fake.actual = .init(enabled: true, limit: 80)
        fake.release()
        let ready = await coordinator.requestAndWait(enabled: true, limit: 80)
        XCTAssertTrue(ready)
        XCTAssertEqual(fake.requests, [65, 80])
    }

    func testMissingXPCReplyTimesOutAndLateReplyIsIgnored() async throws {
        var lateReply: (@Sendable (Result<Int, Error>) -> Void)?
        do {
            let _: Int = try await performXPCRequest(timeout: .milliseconds(20)) { lateReply = $0 }
            XCTFail("Missing helper reply should time out")
        } catch {
            guard case XPCError.timedOut = error else { return XCTFail("Unexpected error: \(error)") }
        }
        lateReply?(.success(42))
        lateReply?(.failure(XPCError.helperUnavailable))
    }

    func testXPCDuplicateReplyAndSubsequentTimeoutResumeOnlyOnce() async throws {
        let value: Int = try await performXPCRequest(timeout: .milliseconds(20)) { finish in
            finish(.success(42))
            finish(.failure(XPCError.helperUnavailable))
        }
        XCTAssertEqual(value, 42)
        try await Task.sleep(for: .milliseconds(40))
    }

    func testXPCTransportErrorCompletesWithoutWaitingForDeadline() async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let _: Int = try await performXPCRequest(timeout: .seconds(8)) { finish in
                finish(.failure(XPCError.helperUnavailable))
            }
            XCTFail("Transport error must propagate")
        } catch {
            XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(200))
        }
    }
}
