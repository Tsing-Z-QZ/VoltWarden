import Foundation
import CoreFoundation
import os.log
import smc_power

private enum Constants {
    static let subsystem =
        "com.srimanachanta.stasis.charging-helper.native"
}

private enum NativeChargeLimitConstants {

    // Apple Smart Charging 配置域
    //
    // 这里只保存 Swift String。
    // 不要把 CFString 存成 static let，
    // 否则 Swift 6 会报 Sendable / concurrency-safe 错误。
    static let domain =
        "com.apple.smartcharging.topoffprotection"

    // 通知 powerd / Smart Charging
    // 重新读取配置
    static let defaultsChangedNotification =
        "com.apple.smartcharging.defaultschanged"

    // 当前 Stasis UI 是 50...100。
    // 先保持现有范围，不在这一阶段放开更低值。
    static let validLimitRange =
        50...100

    static let enabledKey =
        "enabled"

    static let limitKey =
        "mclLimitValue"

    static let featureStateKey =
        "MCLFeatureState"

    static let checkpointKey =
        "checkpoint"

    static let currentStateKey =
        "currentState"

    static let temporaryDisableKey =
        "MCLTempDisabledUntilDate"
}

final class ChargingHelper:
    NSObject,
    ChargingHelperProtocol
{
    private let battery: SMCBattery
    private let adapter: SMCAdapter
    private var lastPowerUIStatus = "not-called"
    private var nativeResetPolicy = NativeLimitResetPolicy()
    private let nativeLimitLock = NSRecursiveLock()

    private let logger = Logger(
        subsystem: Constants.subsystem,
        category: "ChargingHelper"
    )

    init(
        battery: SMCBattery,
        adapter: SMCAdapter
    ) {
        self.battery = battery
        self.adapter = adapter

        super.init()

        logger.info(
            """
            Initialized \
            (charging=\(battery.capabilities.inhibitChargeControl), \
            discharge=\(battery.capabilities.forceDischargeControl), \
            magSafe=\(adapter.capabilities.magSafeControl))
            """
        )
    }

    func getControlStatus(reply: @escaping @Sendable (String) -> Void) {
        nativeLimitLock.lock()
        defer { nativeLimitLock.unlock() }
        let domain = NativeChargeLimitConstants.domain as CFString
        var result: [String: Any] = [
            "helperPID": ProcessInfo.processInfo.processIdentifier,
            "helperBuild": "20260927-reset-once",
            "powerUI": lastPowerUIStatus,
            "forceDischargeSupported": battery.capabilities.forceDischargeControl,
            "chargingGateSupported": battery.capabilities.inhibitChargeControl,
        ]
        if battery.capabilities.forceDischargeControl {
            result["forceDischarge"] = try? battery.getForceDischarging()
        }
        if battery.capabilities.inhibitChargeControl {
            result["chargingInhibited"] = try? battery.getChargingInhibited()
        }
        for key in ["mclLimitValue", "MCLFeatureState", "enabled"] {
            result[key] = CFPreferencesCopyValue(
                key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
            )
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys),
           let text = String(data: data, encoding: .utf8) {
            reply(text)
        } else {
            reply("Control status could not be serialized")
        }
    }

    /// Ask powerd to apply the target through its own Smart Charge client.
    /// Runtime signature verified on macOS 27: B28@0:8C16^@20.
    /// Older systems or targets rejected by PowerUI retain the verified prefs path.
    private func applyLimitThroughPowerUI(_ limit: Int, resetPolicy: Bool) -> Bool {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/PowerUI.framework"),
              bundle.load(),
              let type = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else { return false }
        let base = type.init()
        let initializer = NSSelectorFromString("initWithClientName:")
        guard base.responds(to: initializer),
              let object = base.perform(initializer, with: "Stasis" as NSString)?.takeUnretainedValue() as? NSObject else { return false }
        let selector = NSSelectorFromString("setMCLLimit:error:")
        guard object.responds(to: selector) else { return false }
        typealias SetLimit = @convention(c) (
            AnyObject, Selector, UInt8, AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> Bool
        if resetPolicy {
            // A new target may need one reset to evict a stale powerd policy.
            // Repeating it on retries reinstalls the default 80% before a custom
            // 75% preference has time to settle, causing prolonged overcharge.
            let disable = NSSelectorFromString("disableMCL:")
            if object.responds(to: disable) {
                typealias Disable = @convention(c) (
                    AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?
                ) -> Bool
                let deactivate = unsafeBitCast(object.method(for: disable), to: Disable.self)
                var disableError: NSError?
                _ = deactivate(object, disable, &disableError)
            }

            let enable = NSSelectorFromString("enableMCL:")
            if object.responds(to: enable) {
                typealias Enable = @convention(c) (
                    AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?
                ) -> Bool
                let activate = unsafeBitCast(object.method(for: enable), to: Enable.self)
                var enableError: NSError?
                _ = activate(object, enable, &enableError)
            }
        }
        let availableSelector = NSSelectorFromString("availableChargeLimitsWithError:")
        if object.responds(to: availableSelector),
           let values = object.perform(availableSelector, with: nil)?.takeUnretainedValue() as? [NSNumber],
           let minimum = values.map({ $0.intValue }).min(), limit < minimum {
            lastPowerUIStatus = "target=\(limit) reset=\(resetPolicy); native preferences fallback"
            return false
        }
        let method = unsafeBitCast(object.method(for: selector), to: SetLimit.self)
        var error: NSError?
        let accepted = method(object, selector, UInt8(limit), &error)
        lastPowerUIStatus = "target=\(limit) reset=\(resetPolicy) accepted=\(accepted) error=\(error?.localizedDescription ?? "none")"
        logger.info("PowerUI setMCLLimit: \(self.lastPowerUIStatus)")
        return accepted
    }

    // MARK: - Native Charge Limit

    /// 设置 macOS 原生 Manual Charge Limit。
    ///
    /// 这是 macOS 26.4 / 27 的新 Smart Charging 路径。
    ///
    /// 注意：
    ///
    /// 这个函数负责的是：
    ///
    /// 已经 enableMCL
    /// ↓
    /// 把系统目标从例如 80%
    /// 改成 75%
    /// ↓
    /// powerd 真正建立
    /// manualChargeLimit = 75
    ///
    /// PowerUISmartChargeClient.enableMCL()
    /// 会由主 App 负责。
    ///
    /// 主动放电仍然由 CHIE 负责，
    /// 与 Native Charge Limit 是两套独立机制。
    func applyNativeChargeLimit(
        limit: Int,
        reply:
            @escaping @Sendable
            (Bool, String?) -> Void
    ) {
        nativeLimitLock.lock()
        defer { nativeLimitLock.unlock() }
        guard
            NativeChargeLimitConstants
                .validLimitRange
                .contains(limit)
        else {
            let message =
                """
                Invalid native charge limit: \
                \(limit). Expected 50...100.
                """

            logger.error(
                "\(message)"
            )

            reply(
                false,
                message
            )

            return
        }

        // Use the daemon's setter BEFORE touching its preferences. Prewriting
        // the requested value can make the setter short-circuit as "unchanged"
        // while the actual power-source limit still holds the preceding value.
        //
        // For an active limit, a successful setter is still followed by the
        // synchronized preference write, transient-state clear, and Darwin
        // notification below. On macOS 27 the setter can update MCLLimitValue
        // and return true while powerd continues enforcing the previous limit.
        // 100 is represented by PowerUI as unrestricted charging and must not
        // be turned back into an enabled MCL preference state afterward.
        let resetPolicy = nativeResetPolicy.beginRequest(target: limit)
        let powerUIAccepted = applyLimitThroughPowerUI(limit, resetPolicy: resetPolicy)
        if powerUIAccepted && limit == 100 {
            reply(true, nil)
            return
        }

        // MARK: CoreFoundation Values

        // Swift 6 不允许把 CFString
        // 作为全局 static let 保存，
        // 因为 CFString 不符合 Sendable。
        //
        // 所以常量层使用 Swift String，
        // 只有真正调用 CFPreferences 时
        // 才在当前函数作用域转换。

        let domain =
            NativeChargeLimitConstants
                .domain
            as CFString

        let defaultsChangedNotification =
            NativeChargeLimitConstants
                .defaultsChangedNotification
            as CFString

        let enabledKey =
            NativeChargeLimitConstants
                .enabledKey
            as CFString

        let limitKey =
            NativeChargeLimitConstants
                .limitKey
            as CFString

        let featureStateKey =
            NativeChargeLimitConstants
                .featureStateKey
            as CFString

        let checkpointKey =
            NativeChargeLimitConstants
                .checkpointKey
            as CFString

        let currentStateKey =
            NativeChargeLimitConstants
                .currentStateKey
            as CFString

        let temporaryDisableKey =
            NativeChargeLimitConstants
                .temporaryDisableKey
            as CFString

        // 实机已经确认：
        //
        // CurrentUser + CurrentHost
        // → 不会建立正确的 manualChargeLimit
        //
        // CurrentUser + AnyHost
        // → 正确
        //
        // 这里运行在 privileged helper，
        // 所以 CurrentUser 实际就是 root。

        let user =
            kCFPreferencesCurrentUser

        let host =
            kCFPreferencesAnyHost

        // MARK: 1. enabled = false

        // 注意：
        //
        // 这个 enabled 不是
        // “Stasis 是否启用限充”的开关。
        //
        // 我们从实际可工作路径中确认，
        // 这里需要保持 false。

        CFPreferencesSetValue(
            enabledKey,
            kCFBooleanFalse,
            domain,
            user,
            host
        )

        // MARK: 2. mclLimitValue = target

        CFPreferencesSetValue(
            limitKey,
            NSNumber(
                value: limit
            ),
            domain,
            user,
            host
        )

        // MARK: 3. MCLFeatureState = 1

        CFPreferencesSetValue(
            featureStateKey,
            NSNumber(
                value: 1
            ),
            domain,
            user,
            host
        )

        // MARK: 4. Clear Transient State

        // 我们的独立测试已经实机验证：
        //
        // 清掉这几个 transient state
        // 再发送 defaultschanged，
        //
        // 可以让运行中的系统 MCL
        // 从 80% 更新成 75%。

        CFPreferencesSetValue(
            checkpointKey,
            nil,
            domain,
            user,
            host
        )

        CFPreferencesSetValue(
            currentStateKey,
            nil,
            domain,
            user,
            host
        )

        CFPreferencesSetValue(
            temporaryDisableKey,
            nil,
            domain,
            user,
            host
        )

        // MARK: 5. Synchronize

        let synchronized =
            CFPreferencesSynchronize(
                domain,
                user,
                host
            )

        guard synchronized else {
            let message =
                """
                Failed to synchronize native \
                charge limit preferences.
                """

            logger.error(
                "\(message)"
            )

            reply(
                false,
                message
            )

            return
        }

        // MARK: 6. Verify Limit

        // 不能只相信 SetValue 没报错。
        // 和 SMC 控制一样，
        // 写完之后必须回读。

        guard
            let verifiedLimit =
                CFPreferencesCopyValue(
                    limitKey,
                    domain,
                    user,
                    host
                )
                as? NSNumber
        else {
            let message =
                """
                Failed to read back \
                mclLimitValue.
                """

            logger.error(
                "\(message)"
            )

            reply(
                false,
                message
            )

            return
        }

        guard
            verifiedLimit.intValue
                == limit
        else {
            let message =
                """
                Native charge limit verification \
                failed. Requested=\(limit), \
                read back=\(verifiedLimit.intValue)
                """

            logger.error(
                "\(message)"
            )

            reply(
                false,
                message
            )

            return
        }

        // MARK: 7. Verify Feature State

        guard
            let verifiedFeatureState =
                CFPreferencesCopyValue(
                    featureStateKey,
                    domain,
                    user,
                    host
                )
                as? NSNumber
        else {
            let message =
                """
                Failed to read back \
                MCLFeatureState.
                """

            logger.error(
                "\(message)"
            )

            reply(
                false,
                message
            )

            return
        }

        guard
            verifiedFeatureState.intValue
                == 1
        else {
            let message =
                """
                Native MCL feature state \
                verification failed. \
                Expected=1, \
                read back=\(
                    verifiedFeatureState.intValue
                )
                """

            logger.error(
                "\(message)"
            )

            reply(
                false,
                message
            )

            return
        }

        // MARK: 8. Notify powerd

        // 告诉 macOS：
        //
        // Smart Charging 配置已经改变，
        // 请重新读取。
        //
        // 我们已经实机验证：
        //
        // manualChargeLimit 80
        // ↓
        // 写入 target = 75
        // ↓
        // 发这个 notification
        // ↓
        // manualChargeLimit 75

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),

            CFNotificationName(
                rawValue:
                    defaultsChangedNotification
            ),

            nil,
            nil,
            true
        )

        logger.info(
            """
            Native charge limit applied: \
            \(limit)%
            """
        )

        reply(
            true,
            nil
        )
    }

    // MARK: - Charging

    func manageBatteryCharging(
        enabled: Bool,
        reply:
            @escaping @Sendable
            (Bool, String?) -> Void
    ) {
        do {
            guard
                battery.capabilities
                    .inhibitChargeControl
            else {
                reply(
                    false,
                    """
                    Charging control is not \
                    supported on this device
                    """
                )

                return
            }

            let targetInhibited =
                !enabled

            let currentlyInhibited =
                try battery
                    .getChargingInhibited()

            if currentlyInhibited
                != targetInhibited
            {
                try battery
                    .setChargingInhibited(
                        targetInhibited
                    )

                logger.debug(
                    """
                    Requested charging inhibited: \
                    \(targetInhibited)
                    """
                )
            }

            // 写完以后必须回读。
            //
            // 旧版本的问题：
            //
            // setChargingInhibited()
            // 没抛异常
            // ↓
            // 直接 reply(true)
            //
            // 但这并不能证明 SMC
            // 最终真的接受了状态。

            let verifiedInhibited =
                try battery
                    .getChargingInhibited()

            guard
                verifiedInhibited
                    == targetInhibited
            else {
                let message =
                    """
                    Charging state verification \
                    failed. Requested inhibited=\
                    \(targetInhibited), \
                    read back=\
                    \(verifiedInhibited)
                    """

                logger.error(
                    "\(message)"
                )

                reply(
                    false,
                    message
                )

                return
            }

            logger.info(
                """
                Charging state verified: \
                enabled=\(enabled)
                """
            )

            reply(
                true,
                nil
            )

        } catch {
            logger.error(
                """
                manageBatteryCharging failed: \
                \(error.localizedDescription)
                """
            )

            reply(
                false,
                error.localizedDescription
            )
        }
    }

    // MARK: - External Power / Force Discharge

    func manageExternalPower(
        enabled: Bool,
        reply:
            @escaping @Sendable
            (Bool, String?) -> Void
    ) {
        do {
            guard
                battery.capabilities
                    .forceDischargeControl
            else {
                reply(
                    false,
                    """
                    Adapter control is not \
                    supported on this device
                    """
                )

                return
            }

            let targetForceDischarging =
                !enabled

            let currentlyDischarging =
                try battery
                    .getForceDischarging()

            if currentlyDischarging
                != targetForceDischarging
            {
                try battery
                    .setForceDischarging(
                        targetForceDischarging
                    )

                logger.debug(
                    """
                    Requested force discharging: \
                    \(targetForceDischarging)
                    """
                )
            }

            // CHIE 写入之后同样回读验证。

            let verifiedDischarging =
                try battery
                    .getForceDischarging()

            guard
                verifiedDischarging
                    == targetForceDischarging
            else {
                let message =
                    """
                    Adapter state verification \
                    failed. Requested forceDischarge=\
                    \(targetForceDischarging), \
                    read back=\
                    \(verifiedDischarging)
                    """

                logger.error(
                    "\(message)"
                )

                reply(
                    false,
                    message
                )

                return
            }

            logger.info(
                """
                External power state verified: \
                enabled=\(enabled)
                """
            )

            reply(
                true,
                nil
            )

        } catch {
            logger.error(
                """
                manageExternalPower failed: \
                \(error.localizedDescription)
                """
            )

            reply(
                false,
                error.localizedDescription
            )
        }
    }

    // MARK: - MagSafe LED

    func manageMagsafeLED(
        target: UInt8,
        reply:
            @escaping @Sendable
            (Bool, String?) -> Void
    ) {
        do {
            guard
                adapter.capabilities
                    .magSafeControl
            else {
                reply(
                    false,
                    """
                    MagSafe LED control is not \
                    supported on this device
                    """
                )

                return
            }

            guard
                let ledState =
                    MagSafeLEDState(
                        rawValue: target
                    )
            else {
                reply(
                    false,
                    """
                    Invalid MagSafe LED state: \
                    \(target)
                    """
                )

                return
            }

            let currentState =
                try adapter
                    .getMagSafeLEDState()

            if currentState
                != ledState
            {
                try adapter
                    .setMagSafeLEDState(
                        ledState
                    )

                logger.debug(
                    """
                    Requested MagSafe LED: \
                    \(ledState.rawValue)
                    """
                )
            }

            // LED 也进行回读验证。

            let verifiedState =
                try adapter
                    .getMagSafeLEDState()

            guard
                verifiedState
                    == ledState
            else {
                let message =
                    """
                    MagSafe LED verification \
                    failed. Requested=\
                    \(ledState.rawValue), \
                    read back=\
                    \(verifiedState.rawValue)
                    """

                logger.error(
                    "\(message)"
                )

                reply(
                    false,
                    message
                )

                return
            }

            logger.info(
                """
                MagSafe LED verified: \
                \(ledState.rawValue)
                """
            )

            reply(
                true,
                nil
            )

        } catch {
            logger.error(
                """
                manageMagsafeLED failed: \
                \(error.localizedDescription)
                """
            )

            reply(
                false,
                error.localizedDescription
            )
        }
    }

    // MARK: - Reset

    func resetToDefaults() {
        // Restore external power first, even if a separate gate or LED reset fails.
        if battery.capabilities.forceDischargeControl {
            do {
                try battery.setForceDischarging(false)
            } catch {
                logger.error("CHIE reset failed: \(error.localizedDescription)")
            }
        }
        do {
            // 旧式 SMC Charging Inhibit
            //
            // 你的 M4 Pro 上目前 unsupported，
            // 但保留旧设备兼容逻辑。

            if battery.capabilities
                .inhibitChargeControl
            {
                try battery
                    .setChargingInhibited(
                        false
                    )
            }

            // CHIE Force Discharge
            //
            // 必须恢复成 false，
            // 避免 Helper 被重启之后
            // 留下主动放电状态。

            // MagSafe LED 恢复系统控制。

            if adapter.capabilities
                .magSafeControl
            {
                try adapter
                    .setMagSafeLEDState(
                        .reset
                    )
            }

            logger.info(
                "SMC keys reset to defaults"
            )

        } catch {
            logger.error(
                """
                resetToDefaults failed: \
                \(error.localizedDescription)
                """
            )
        }
    }
}
