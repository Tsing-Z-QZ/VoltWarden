import Foundation
import os.log

@MainActor
final class NativeChargeLimitCoordinator {

    // MARK: - Services

    struct SystemNativeChargeLimitState: Equatable, Sendable {
        let enabled: Bool
        let limit: Int?
    }

    /// Hardware operations are injected so the real wait/coalescing path can be
    /// exercised without writing battery settings in unit tests.
    struct Operations {
        var isAvailable: () -> Bool
        var enable: () throws -> Void
        var disable: () throws -> Void
        var applyLimit: (Int) async throws -> Void
        var readSystemState: () async -> SystemNativeChargeLimitState?
        var refreshMetrics: () -> Void
        var record: (String, String) -> Void = { _, _ in }
    }

    private let operations: Operations

    // MARK: - Desired State

    // ChargeManager 最终希望系统达到的状态。

    private var desiredEnabled =
        false

    private var desiredLimit:
        Int?

    // MARK: - Applied State

    // 我们已经成功执行过的状态。
    //
    // 这里只作为减少重复调用的缓存，
    // 不代表永远相信系统状态。

    private var appliedEnabled:
        Bool?

    private var appliedLimit:
        Int?

    // MARK: - Tasks

    private var controlTask:
        Task<Void, Never>?

    private var retryTask:
        Task<Void, Never>?

    private var requestDebounceTask:
        Task<Void, Never>?

    private var settleVerificationTask:
        Task<Void, Never>?

    private var permanentlyBlocked = false
    private var requestRevision = 0
    private var retryAttempt = 0
    private var mustApplyDesiredState = false
    private var requiresFreshApplyBeforeReady = false
    private(set) var isSuspended = false

    // MARK: - Logger

    private let logger =
        Logger(
            subsystem:
                "com.srimanachanta.stasis",

            category:
                "NativeChargeLimitCoordinator"
        )

    // MARK: - Init

    convenience init(
        batteryService: BatteryService,
        backend: NativeChargeLimitBackend = NativeChargeLimitBackend()
    ) {
        self.init(operations: Operations(
            isAvailable: { backend.isAvailable },
            enable: { try backend.ensureEnabled() },
            disable: { try backend.disable() },
            applyLimit: { try await batteryService.applyNativeChargeLimit(limit: $0) },
            readSystemState: { await Self.readSystemNativeChargeLimitState() },
            refreshMetrics: { batteryService.scheduleTransitionPolls() },
            record: { ControlDiagnostics.shared.record($0, $1) }
        ))
    }

    init(operations: Operations) {
        self.operations = operations
    }

    // MARK: - Availability

    var isAvailable:
        Bool
    {
        operations.isAvailable()
    }

    // MARK: - Request

    /// 请求系统最终保持某个原生限充状态。
    ///
    /// 例如：
    ///
    /// request(
    ///     enabled: true,
    ///     limit: 75
    /// )
    ///
    /// 最终执行：
    ///
    /// PowerUI enableMCL
    /// ↓
    /// privileged helper 写入 75
    /// ↓
    /// powerd 建立 manualChargeLimit=75
    ///
    /// 如果之后很快又收到：
    ///
    /// 80
    /// 75
    /// 100
    ///
    /// 不会同时开三个 Task 去抢状态，
    /// 而是串行执行，并最终收敛到最新目标。
    func request(
        enabled: Bool,
        limit: Int?
    ) {
        let wasEnabled = desiredEnabled
        let changed = desiredEnabled != enabled || desiredLimit != (enabled ? limit : nil)
        let shouldDebounce = changed && wasEnabled && enabled
        if changed {
            permanentlyBlocked = false
            retryAttempt = 0
            retryTask?.cancel()
            retryTask = nil
            requestDebounceTask?.cancel()
            requestDebounceTask = nil
            requestRevision &+= 1
            mustApplyDesiredState = true
            requiresFreshApplyBeforeReady = wasEnabled && enabled
            operations.record("NATIVE_REQUEST", "revision=\(requestRevision) enabled=\(enabled) target=\(limit.map(String.init) ?? "none")")
        }
        if enabled {

            guard
                let limit,
                (50...100)
                    .contains(limit)
            else {
                logger.error(
                    """
                    Invalid native charge \
                    limit request
                    """
                )

                return
            }

            desiredEnabled =
                true

            desiredLimit =
                limit

        } else {

            desiredEnabled =
                false

            desiredLimit =
                nil
        }

        guard !isSuspended else { return }
        if shouldDebounce {
            let revision = requestRevision
            requestDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(75))
                guard let self, !Task.isCancelled,
                      revision == self.requestRevision else { return }
                self.requestDebounceTask = nil
                self.startControlTaskIfNeeded()
            }
        } else if requestDebounceTask == nil {
            startControlTaskIfNeeded()
        }
        if changed {
            scheduleSettleVerification(for: requestRevision)
        }
    }


    // MARK: - Request And Wait

    /// 请求一个 Native MCL 状态，
    /// 并等待 Coordinator 真正执行完成。
    ///
    /// Automatic Discharge 会用这个方法保证：
    ///
    /// Native target = 75
    /// ↓
    /// 确认已经写入
    /// ↓
    /// 再开启 CHIE 主动放电
    ///
    /// 从而避免主动放电先于系统限充目标建立。
    func requestAndWait(
        enabled: Bool,
        limit: Int?,
        timeout: Duration = .seconds(5),
        isCurrent: @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard !Task.isCancelled, !isSuspended, isCurrent() else { return false }
        request(
            enabled: enabled,
            limit: limit
        )

        let waitingRevision = requestRevision
        let clock =
            ContinuousClock()

        let deadline =
            clock.now
            .advanced(
                by: timeout
            )

        // requestAndWait() 等的是“这一次请求”本身，
        // 不能直接用 controlStateIsSatisfied()。
        //
        // controlStateIsSatisfied() 比较的是全局 desired state；
        // 在等待期间如果 ChargeManager 又重复 request()，
        // 它并不能准确描述当前调用正在等的目标。
        //
        // 另外，appliedEnabled / appliedLimit 只是本地缓存。
        // macOS 27 上已经实机出现过：
        //
        // pmset -g battlimit
        // → manualChargeLimit = 75
        //
        // 但 Coordinator 缓存尚未同步，
        // 导致 Automatic Discharge 被错误阻止。
        //
        // 因此这里保留本地缓存作为快速路径，
        // 同时用 pmset 的系统实际状态做只读兜底确认。
        var nextSystemVerification =
            clock.now

        while
            clock.now < deadline
        {
            guard !Task.isCancelled, !isSuspended, isCurrent(), requestRevision == waitingRevision else {
                operations.record("NATIVE_WAIT", "superseded target=\(limit.map(String.init) ?? "none"); returning to latest control plan")
                return false
            }
            if !requiresFreshApplyBeforeReady,
               appliedStateSatisfies(
                enabled: enabled,
                limit: limit
            ) {

                logger.debug(
                    """
                    Native MCL request \
                    completed from applied state
                    """
                )

                return true
            }

            let now =
                clock.now

            if now >= nextSystemVerification {

                if !requiresFreshApplyBeforeReady,
                   let systemState =
                    await operations.readSystemState(),
                   systemStateSatisfies(
                        systemState,
                        enabled: enabled,
                        limit: limit
                   )
                {
                    guard !Task.isCancelled, !isSuspended, isCurrent(), requestRevision == waitingRevision else { return false }
                    // 系统已经真正建立目标时，
                    // 同步本地缓存，避免后续重复写入。
                    appliedEnabled =
                        enabled

                    appliedLimit =
                        enabled
                        ? limit
                        : nil
                    mustApplyDesiredState = false
                    retryTask?.cancel()
                    retryTask = nil
                    operations.record("NATIVE_VERIFIED", "late system confirmation target=\(limit.map(String.init) ?? "disabled")")

                    logger.info(
                        """
                        Native MCL request verified \
                        from system state: \
                        enabled=\(enabled), \
                        limit=\(String(describing: limit))
                        """
                    )

                    return true
                }

                nextSystemVerification =
                    now.advanced(
                        by: .milliseconds(250)
                    )
            }

            try?
                await Task.sleep(
                    for:
                        .milliseconds(50)
                )

            if Task.isCancelled {
                return false
            }
        }

        guard !Task.isCancelled, !isSuspended, isCurrent(), requestRevision == waitingRevision else { return false }
        let systemState = await operations.readSystemState()
        operations.record("NATIVE_TIMEOUT", "target=\(limit.map(String.init) ?? "none") observed=\(systemState?.limit.map(String.init) ?? "unknown")")

        logger.error(
            """
            Timed out waiting for Native MCL state: \
            requestedEnabled=\(enabled), \
            requestedLimit=\(String(describing: limit)), \
            appliedEnabled=\(String(describing: self.appliedEnabled)), \
            appliedLimit=\(String(describing: self.appliedLimit)), \
            systemEnabled=\(String(describing: systemState?.enabled)), \
            systemLimit=\(String(describing: systemState?.limit))
            """
        )

        return false
    }

    // MARK: - Wait State Verification

    private func appliedStateSatisfies(
        enabled: Bool,
        limit: Int?
    ) -> Bool {

        if !enabled {
            return
                appliedEnabled
                == false
        }

        guard
            let limit
        else {
            return false
        }

        return
            appliedEnabled
                == true
            &&
            appliedLimit
                == limit
    }

    private func systemStateSatisfies(
        _ state: SystemNativeChargeLimitState,
        enabled: Bool,
        limit: Int?
    ) -> Bool {

        if !enabled {
            return
                state.enabled
                == false
        }

        // PowerUI represents a 100% target as unrestricted charging. This is
        // the successful Top Up/calibration state, not a failed 100% hold.
        if limit == 100 && !state.enabled { return true }

        guard
            let limit
        else {
            return false
        }

        return
            state.enabled
            &&
            state.limit
                == limit
    }

    /// 读取 macOS 当前真正公开给 pmset 的电池上限状态。
    ///
    /// 这里只做只读验证，不负责设置 MCL，
    /// 因此不会碰已经验证成功的 Native Hold 路径。
    private static func readSystemNativeChargeLimitState()
        async -> SystemNativeChargeLimitState?
    {
        await Task.detached(priority: .utility) {
            readSystemNativeChargeLimitStateSync()
        }.value
    }

    nonisolated private static func readSystemNativeChargeLimitStateSync()
        -> SystemNativeChargeLimitState?
    {
        let process =
            Process()

        process.executableURL =
            URL(
                fileURLWithPath:
                    "/usr/bin/pmset"
            )

        process.arguments =
            [
                "-g",
                "battlimit",
            ]

        let outputPipe =
            Pipe()

        process.standardOutput =
            outputPipe

        process.standardError =
            outputPipe

        do {
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()
            // A stuck diagnostic process must not outlive a control-plan wait.
            guard exited.wait(timeout: .now() + 1) == .success else {
                if process.isRunning { process.terminate() }
                return nil
            }
        } catch {
            return nil
        }

        let data =
            outputPipe
            .fileHandleForReading
            .readDataToEndOfFile()

        guard
            process.terminationStatus == 0,
            let output =
                String(
                    data: data,
                    encoding: .utf8
                )
        else {
            return nil
        }

        return parseSystemState(output)
    }

    nonisolated static func parseSystemState(_ output: String) -> SystemNativeChargeLimitState? {
        if output.contains(
            "No battery level limits set"
        ) {
            return
                SystemNativeChargeLimitState(
                    enabled: false,
                    limit: nil
                )
        }

        let pattern = #"\{[^{}]*\}"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: .dotMatchesLineSeparators
        ) else { return nil }
        let nsOutput = output as NSString
        let blocks = regex.matches(
            in: output,
            range: NSRange(location: 0, length: nsOutput.length)
        ).map { nsOutput.substring(with: $0.range) }
        guard !blocks.isEmpty else { return nil }

        // Never combine the reason from one power-source dictionary
        // with the percentage from another. Conflicting snapshots are unknown.
        let limits: [Int?] = blocks.map { block in
            guard block.contains("chargeSocLimitReason = manualChargeLimit") else {
                return nil
            }
            guard let range = block.range(
                of: #"chargeSocLimitSoc\s*=\s*(\d+)"#,
                options: .regularExpression
            ) else { return nil }
            return Int(block[range].split(separator: "=").last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        guard let first = limits.first ?? nil,
              limits.allSatisfy({ $0 == first }) else { return nil }
        return SystemNativeChargeLimitState(enabled: true, limit: first)
    }

    // MARK: - Sleep / Battery Power

    /// Keep the saved target and the system's existing Hold, without polling or
    /// retrying while asleep/off AC. An in-flight helper call retains its queue
    /// slot until it returns, so reconnecting cannot start an overlapping write.
    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        requestRevision &+= 1
        retryAttempt = 0
        retryTask?.cancel()
        retryTask = nil
        requestDebounceTask?.cancel()
        requestDebounceTask = nil
        settleVerificationTask?.cancel()
        settleVerificationTask = nil
        operations.record(suspended ? "NATIVE_PAUSE" : "NATIVE_RESUME",
                          "revision=\(requestRevision) target=\(desiredLimit.map(String.init) ?? "none")")
        if !suspended {
            invalidateAppliedState()
            scheduleSettleVerification(for: requestRevision)
        }
    }

    // MARK: - Invalidate

    /// 睡眠唤醒、Helper 重启等情况下，
    /// 不能继续相信本地 applied 缓存。
    ///
    /// 清空缓存以后重新确认一次。
    func invalidateAppliedState() {

        appliedEnabled =
            nil

        appliedLimit =
            nil

        startControlTaskIfNeeded()
    }

    // MARK: - Start

    private func startControlTaskIfNeeded() {

        guard
            !isSuspended,
            controlTask == nil,
            retryTask == nil,
            requestDebounceTask == nil,
            (!controlStateIsSatisfied() || mustApplyDesiredState),
            !permanentlyBlocked
        else {
            return
        }

        retryTask?
            .cancel()

        retryTask =
            nil

        controlTask =
            Task { [weak self] in

                guard
                    let self
                else {
                    return
                }

                let success =
                    await self
                    .flushDesiredState()

                self.controlTask =
                    nil
                guard !Task.isCancelled, !self.isSuspended else { return }

                if !success && !self.permanentlyBlocked {

                    self
                        .scheduleRetry()

                } else if
                    !self
                    .controlStateIsSatisfied()
                {
                    // 执行旧命令期间，
                    // ChargeManager 又产生了
                    // 一个更新的目标。
                    //
                    // 继续执行最新状态。

                    self
                        .startControlTaskIfNeeded()
                }
            }
    }

    // MARK: - Flush

    private func flushDesiredState()
        async -> Bool
    {
        while
            !Task.isCancelled && !isSuspended
        {
            // A slider can publish many values in a few milliseconds. If a
            // newer target is still inside the short coalescing window, wait
            // for that window before issuing another privileged write. An
            // already running helper call cannot be cancelled safely, but all
            // values queued behind it still collapse to the final target.
            if let requestDebounceTask {
                await requestDebounceTask.value
                guard !Task.isCancelled, !isSuspended else { return true }
                continue
            }

            let revision = requestRevision
            let enabled =
                desiredEnabled

            let limit =
                desiredLimit

            // A verified existing Hold is authoritative, including on startup
            // when PowerUI's enabled flag or our applied cache can lag behind it.
            if !mustApplyDesiredState,
               let actual = await operations.readSystemState(),
               systemStateSatisfies(actual, enabled: enabled, limit: limit) {
                guard !Task.isCancelled, !isSuspended else { return true }
                if revision != requestRevision { continue }
                appliedEnabled = enabled
                appliedLimit = enabled ? limit : nil
                retryAttempt = 0
                return true
            }
            guard !Task.isCancelled, !isSuspended else { return true }
            if revision != requestRevision { continue }

            // -----------------------------------------
            // Disable Native MCL
            // -----------------------------------------

            if !enabled {

                if mustApplyDesiredState || appliedEnabled
                    != false
                {
                    logger.info(
                        """
                        Disabling native \
                        Manual Charge Limit
                        """
                    )

                    do {

                        try operations.disable()

                        appliedEnabled =
                            false

                        appliedLimit =
                            nil

                        if revision == requestRevision {
                            mustApplyDesiredState = false
                            requiresFreshApplyBeforeReady = false
                        }

                    } catch {

                        if Self.isPermanentError(error) { permanentlyBlocked = true }

                        logger.error(
                            """
                            Failed to disable \
                            native MCL: \
                            \(error.localizedDescription)
                            """
                        )

                        return false
                    }
                }

                if controlStateIsSatisfied() {
                    return true
                }

                continue
            }

            // -----------------------------------------
            // Enabled requires a target
            // -----------------------------------------

            guard
                let limit
            else {

                logger.error(
                    """
                    Native MCL is enabled \
                    but no target was supplied
                    """
                )

                return false
            }

            // -----------------------------------------
            // 1. Ensure PowerUI MCL Enabled
            // -----------------------------------------

            if appliedEnabled
                != true
            {
                logger.info(
                    """
                    Ensuring native MCL \
                    is enabled
                    """
                )

                do {

                    try operations.enable()

                    appliedEnabled =
                        true

                } catch {

                    if Self.isPermanentError(error) { permanentlyBlocked = true }

                    logger.error(
                        """
                        Failed to enable \
                        native MCL: \
                        \(error.localizedDescription)
                        """
                    )

                    return false
                }
            }

            // -----------------------------------------
            // 2. Apply Real Target
            // -----------------------------------------

            // PowerUI 本身先负责把
            // Manual Charge Limit 环境建立起来。
            //
            // 然后 privileged helper
            // 才负责写：
            //
            // mclLimitValue = 75
            //
            // 并通知 powerd。

            if mustApplyDesiredState || appliedLimit
                != limit
            {
                logger.info(
                    """
                    Applying native charge \
                    limit: \(limit)%
                    """
                )

                do {

                    operations.record(
                        "NATIVE_COMMIT",
                        "revision=\(revision) target=\(limit)"
                    )

                    try await operations.applyLimit(limit)

                    guard !Task.isCancelled, !isSuspended else { return true }
                    if revision != requestRevision { continue }
                    operations.record("NATIVE_ACK", "helper accepted target=\(limit); verifying powerd state")
                    // A fresh write has acknowledged. A matching later system
                    // reading can now complete this revision without another reset.
                    // ACK alone still never marks the native limit as applied.
                    mustApplyDesiredState = false
                    requiresFreshApplyBeforeReady = false
                    var verified = false
                    for _ in 0..<20 {
                        if Task.isCancelled || isSuspended || revision != requestRevision { break }
                        if let actual = await operations.readSystemState(),
                           systemStateSatisfies(actual, enabled: true, limit: limit) {
                            verified = true
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard !Task.isCancelled, !isSuspended else { return true }
                    if revision != requestRevision { continue }
                    guard verified else {
                        appliedLimit = nil
                        operations.record("NATIVE_UNCONFIRMED", "target=\(limit); helper acknowledgement did not establish the system limit")
                        return false
                    }
                    appliedLimit = limit
                    mustApplyDesiredState = false
                    requiresFreshApplyBeforeReady = false
                    retryAttempt = 0
                    operations.record("NATIVE_VERIFIED", limit == 100
                        ? "system permits charging to 100%"
                        : "system manualChargeLimit=\(limit)")

                    operations.refreshMetrics()

                } catch {

                    if Self.isPermanentError(error) { permanentlyBlocked = true }

                    logger.error(
                        """
                        Failed to apply native \
                        charge limit \(limit)%: \
                        \(error.localizedDescription)
                        """
                    )

                    return false
                }
            }

            // -----------------------------------------
            // 3. Check for newer request
            // -----------------------------------------

            if controlStateIsSatisfied() {

                logger.debug(
                    """
                    Native charge limit \
                    state satisfied: \
                    enabled=\(enabled), \
                    target=\(limit)%
                    """
                )

                return true
            }
        }

        return true
    }

    // MARK: - State

    private static func isPermanentError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("not supported") ||
            message.contains("unsupported") ||
            message.contains("invalid limit")
    }

    private func controlStateIsSatisfied()
        -> Bool
    {
        if !desiredEnabled {

            return
                appliedEnabled
                == false
        }

        guard
            let desiredLimit
        else {
            return false
        }

        return
            appliedEnabled
                == true
            &&
            appliedLimit
                == desiredLimit
    }

    // MARK: - Retry

    private func scheduleRetry() {
        guard !isSuspended, retryTask == nil else { return }
        let delay = min(30, 2 << min(retryAttempt, 4))
        retryAttempt += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.isSuspended else { return }
            self.retryTask = nil
            self.invalidateAppliedState()
        }
    }

    private func scheduleSettleVerification(for revision: Int) {
        settleVerificationTask?.cancel()
        settleVerificationTask = nil
        guard !isSuspended else { return }
        settleVerificationTask = Task { [weak self] in
            // powerd can apply a superseded custom preference several seconds
            // after a newer request. Audit beyond that window and reassert the
            // latest target if the system drifts back to the stale value.
            for delay in [1, 2, 4, 8, 15] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, !self.isSuspended,
                      revision == self.requestRevision else { return }
                guard let actual = await self.operations.readSystemState() else {
                    self.operations.record(
                        "NATIVE_AUDIT_UNKNOWN",
                        "revision=\(revision); keeping current state until the system can be read"
                    )
                    continue
                }
                guard !Task.isCancelled, !self.isSuspended, revision == self.requestRevision else { return }
                if self.systemStateSatisfies(
                    actual,
                    enabled: self.desiredEnabled,
                    limit: self.desiredLimit
                   ) {
                    continue
                }
                self.operations.record(
                    "NATIVE_DRIFT",
                    "revision=\(revision) desired=\(self.desiredLimit.map(String.init) ?? "disabled") observed=\(actual.limit.map(String.init) ?? "disabled")"
                )
                // Do not turn an in-progress settle/retry back into a fresh write.
                // Its verifier must get a chance to accept a late matching limit.
                if self.controlTask != nil || self.retryTask != nil { continue }
                self.appliedEnabled = nil
                self.appliedLimit = nil
                self.retryTask?.cancel()
                self.retryTask = nil
                self.startControlTaskIfNeeded()
            }
        }
    }

    // MARK: - Stop

    /// 这里只停止 Stasis 自己的任务。
    ///
    /// 故意不自动 disableMCL。
    ///
    /// 原因：
    ///
    /// 如果用户只是退出 Stasis，
    /// 已经建立好的系统级 75% Hold
    /// 应该继续由 macOS / powerd 维持，
    /// 而不是 App 一退出就突然恢复充满。
    func stop() {

        controlTask?
            .cancel()

        controlTask =
            nil

        retryTask?
            .cancel()

        retryTask =
            nil

        requestDebounceTask?
            .cancel()

        requestDebounceTask =
            nil

        settleVerificationTask?
            .cancel()

        settleVerificationTask =
            nil
    }
}
