#if SWIFT_PACKAGE
import Foundation

@objc protocol HelperProtocol {
    func readBatteryMetrics(
        reply: @escaping @Sendable (Double, Double, Double) -> Void)
    func readAdapterMetrics(
        reply: @escaping @Sendable (Double, Double, Double) -> Void)
    func getCapabilities(
        reply: @escaping @Sendable (Bool, Bool, Bool, Bool) -> Void)
}

import Foundation

@objc protocol ChargingHelperProtocol {
    func getControlStatus(reply: @escaping @Sendable (String) -> Void)


    // MARK: - Native Charge Limit

    /// 设置 macOS 原生 Manual Charge Limit。
    ///
    /// 例如：
    ///
    /// 80 → 75
    ///
    /// 最终由 macOS / powerd 建立：
    ///
    /// manualChargeLimit = 75
    ///
    /// 这个接口只负责更新 Native MCL 目标。
    /// enableMCL / disableMCL
    /// 会由主程序中的 PowerUI 后端负责。
    func applyNativeChargeLimit(
        limit: Int,
        reply:
            @escaping @Sendable
            (Bool, String?) -> Void
    )

    // MARK: - Legacy Charging Control

    /// 旧式 SMC Charging Inhibit。
    ///
    /// 在支持旧 SMC 控制的机器上使用。
    /// 你的 M4 Pro / macOS 27
    /// 当前已经确认这一能力不可用，
    /// 但继续保留用于兼容旧设备。
    func manageBatteryCharging(
        enabled: Bool,
        reply:
            @escaping @Sendable
            (Bool, String?) -> Void
    )

    // MARK: - Force Discharge

    /// 控制 CHIE Force Discharge。
    ///
    /// enabled = true
    /// → 正常使用外部电源
    ///
    /// enabled = false
    /// → CHIE 主动放电
    func manageExternalPower(
        enabled: Bool,
        reply:
            @escaping @Sendable
            (Bool, String?) -> Void
    )

    // MARK: - MagSafe LED

    func manageMagsafeLED(
        target: UInt8,
        reply:
            @escaping @Sendable
            (Bool, String?) -> Void
    )
}

#endif
