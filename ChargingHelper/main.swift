import Foundation
import Security
import os.log
import smc_power

let logger = Logger(
    subsystem: "com.srimanachanta.stasis.charging-helper.native",
    category: "ServiceDelegate"
)

// MARK: - Probe Hardware

let battery: SMCBattery
let adapter: SMCAdapter

do {
    battery = try SMCBattery.probe()
    adapter = try SMCAdapter.probe()
} catch {
    logger.fault(
        "Failed to probe SMC capabilities: \(error.localizedDescription)"
    )

    print(
        "SMC probe failed: \(error.localizedDescription)"
    )

    exit(1)
}

// MARK: - Development Commands

/*
 用来直接测试新的 SMC 底层。

 不需要先把新的 Helper 塞进 App。

 使用：

 sudo ".build/out/Products/Debug/stasis-charging-helper" --probe

 sudo ".build/out/Products/Debug/stasis-charging-helper" --test-pause

 sudo ".build/out/Products/Debug/stasis-charging-helper" --test-resume
 */

// MARK: Probe

if CommandLine.arguments.contains("--probe") {

    print(
        """
        Charging backend: \(battery.chargingControlBackendDescription)
        Charging supported: \(battery.capabilities.inhibitChargeControl)

        Force-discharge backend: \(battery.forceDischargeBackendDescription)
        Force-discharge supported: \(battery.capabilities.forceDischargeControl)

        MagSafe LED supported: \(adapter.capabilities.magSafeControl)
        """
    )

    if battery.capabilities.inhibitChargeControl {
        do {
            let inhibited =
                try battery.getChargingInhibited()

            print(
                "Charging inhibited now: \(inhibited)"
            )
        } catch {
            print(
                "Unable to read charging state: \(error.localizedDescription)"
            )
        }
    }

    exit(0)
}

// MARK: Pause Charging

if CommandLine.arguments.contains("--test-pause") {

    do {
        // 确保不是 Force Discharge 状态
        if battery.capabilities.forceDischargeControl {
            try battery.setForceDischarging(false)
        }

        // 真正暂停充电
        try battery.setChargingInhibited(true)

        let verified =
            try battery.getChargingInhibited()

        print(
            """
            Pause command completed.
            Backend: \(battery.chargingControlBackendDescription)
            Charging inhibited: \(verified)
            """
        )

        exit(
            verified ? 0 : 2
        )

    } catch {
        print(
            """
            Pause command FAILED.
            Backend: \(battery.chargingControlBackendDescription)
            Error: \(error.localizedDescription)
            """
        )

        exit(2)
    }
}

// MARK: Resume Charging

if CommandLine.arguments.contains("--test-resume") {

    do {
        // 先退出 Force Discharge
        if battery.capabilities.forceDischargeControl {
            try battery.setForceDischarging(false)
        }

        // 恢复正常充电
        try battery.setChargingInhibited(false)

        let verified =
            try battery.getChargingInhibited()

        print(
            """
            Resume command completed.
            Backend: \(battery.chargingControlBackendDescription)
            Charging inhibited: \(verified)
            """
        )

        exit(
            verified ? 2 : 0
        )

    } catch {
        print(
            """
            Resume command FAILED.
            Backend: \(battery.chargingControlBackendDescription)
            Error: \(error.localizedDescription)
            """
        )

        exit(2)
    }
}

// MARK: - XPC Service Delegate

final class ServiceDelegate:
    NSObject,
    NSXPCListenerDelegate,
    @unchecked Sendable
{
    let helper: ChargingHelper

    /*
     所有 XPC 连接状态统一放在同一个串行队列。

     防止：
     - 新连接
     - 旧连接 invalidation
     - 延迟 reset

     同时修改状态。
     */
    private let stateQueue = DispatchQueue(
        label: "com.srimanachanta.stasis.charging-helper.native.connection-state"
    )

    private var activeConnections = 0

    private var pendingReset:
        DispatchWorkItem?

    init(helper: ChargingHelper) {
        self.helper = helper
        super.init()
    }

    // MARK: Accept Connection

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {

        var ownCode: SecCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess,
              let ownCode else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo
        ) == errSecSuccess,
        let info = signingInfo as? [String: Any],
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
        !team.isEmpty else {
            logger.error("Unsigned charging helper cannot authenticate clients")
            return false
        }
        // XPC enforces this requirement on every message, avoiding a PID lookup race.
        newConnection.setCodeSigningRequirement(
            "identifier \"com.srimanachanta.stasis\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        )

        connectionBegan()

        newConnection.exportedInterface =
            NSXPCInterface(
                with: (any ChargingHelperProtocol).self
            )

        newConnection.exportedObject =
            helper

        /*
         这里是上一版报错的位置。

         不再使用：

         self?
             .connectionEnded()

         改成 Swift 6 最普通的 guard 写法。
         */
        newConnection.invalidationHandler = { [weak self] in
            guard let self else {
                return
            }

            self.connectionEnded()
        }

        /*
         interruption 并不等于连接永久失效。

         所以这里只记录，
         不 reset SMC，
         也不 exit。
         */
        newConnection.interruptionHandler = {
            logger.warning(
                "Charging helper XPC connection interrupted"
            )
        }

        newConnection.resume()

        return true
    }

    // MARK: Connection Began

    private func connectionBegan() {

        stateQueue.sync {

            // 如果之前准备执行断线 Reset，
            // 新连接回来以后立即取消。
            pendingReset?.cancel()
            pendingReset = nil

            activeConnections += 1

            logger.info(
                "XPC connection accepted. Active connections: \(self.activeConnections)"
            )
        }
    }

    // MARK: Connection Ended

    private func connectionEnded() {

        stateQueue.async { [weak self] in

            guard let self else {
                return
            }

            if self.activeConnections > 0 {
                self.activeConnections -= 1
            }

            logger.info(
                "XPC connection invalidated. Active connections: \(self.activeConnections)"
            )

            guard self.activeConnections == 0 else {
                return
            }

            self.scheduleSafeReset()
        }
    }

    // MARK: Safe Delayed Reset

    private func scheduleSafeReset() {

        pendingReset?.cancel()

        /*
         老版本：

         XPC 一断
         ↓
         立刻 resetToDefaults()
         ↓
         exit

         新版本：

         XPC 断开
         ↓
         等 5 秒
         ↓
         如果客户端重新连接
         -> 什么都不做

         如果 5 秒还没有连接
         -> 恢复系统默认 SMC 状态
         -> Helper 退出
         */

        let workItem =
            DispatchWorkItem { [weak self] in

                guard let self else {
                    return
                }

                self.stateQueue.async { [weak self] in

                    guard let self else {
                        return
                    }

                    guard self.activeConnections == 0 else {

                        logger.info(
                            "Client reconnected; skipping SMC reset"
                        )

                        return
                    }

                    logger.info(
                        "No XPC client returned within grace period; resetting SMC keys"
                    )

                    self.helper.resetToDefaults()

                    logger.info(
                        "Charging helper exiting after safe reset"
                    )

                    exit(0)
                }
            }

        pendingReset =
            workItem

        DispatchQueue
            .global(qos: .utility)
            .asyncAfter(
                deadline: .now() + 5,
                execute: workItem
            )
    }
}

// MARK: - Start XPC Helper

let helper = ChargingHelper(
    battery: battery,
    adapter: adapter
)

let delegate = ServiceDelegate(
    helper: helper
)

let listener = NSXPCListener(
    machServiceName:
        "com.srimanachanta.stasis.charging-helper.native"
)

listener.delegate =
    delegate

listener.resume()

logger.info(
    """
    Charging helper running. \
    chargingBackend=\(battery.chargingControlBackendDescription), \
    forceDischargeBackend=\(battery.forceDischargeBackendDescription)
    """
)

dispatchMain()
