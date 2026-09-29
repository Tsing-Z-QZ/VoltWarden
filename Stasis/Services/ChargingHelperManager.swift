import Foundation
import Observation
import ServiceManagement
import os.log

enum ChargingHelperStatus {
    case notInstalled
    case requiresApproval
    case installed
}

enum ChargingHelperRefreshPolicy {
    static func shouldRefresh(manageCharging: Bool, hasObservedPowerSource: Bool,
                              adapterConnected: Bool, registeredBuild: String?,
                              currentBuild: String) -> Bool {
        manageCharging && hasObservedPowerSource && !adapterConnected &&
            registeredBuild != currentBuild
    }
}

@MainActor
@Observable
class ChargingHelperManager {

    static let shared =
        ChargingHelperManager()

    // MARK: - Constants

    private static let machServiceName =
        "com.srimanachanta.stasis.charging-helper.native"

    private static let plistName =
        "com.srimanachanta.stasis.charging-helper.native.plist"

    // MARK: - State

    private let service:
        SMAppService

    private var connection:
        NSXPCConnection?

    private let logger = Logger(
        subsystem:
            "com.srimanachanta.stasis",
        category:
            "ChargingHelperManager"
    )

    private(set) var helperStatus:
        ChargingHelperStatus

    // MARK: - Status

    var isInstalled: Bool {
        service.status == .enabled
    }

    var isRegistered: Bool {
        service.status == .enabled || service.status == .requiresApproval
    }

    // MARK: - Init

    private init() {

        service =
            SMAppService.daemon(
                plistName:
                    Self.plistName
            )

        switch service.status {

        case .enabled:
            helperStatus =
                .installed

        case .requiresApproval:
            helperStatus =
                .requiresApproval

        default:
            helperStatus =
                .notInstalled
        }
    }

    // MARK: - Install

    func install() throws {

        logger.info(
            "Registering charging helper daemon"
        )

        do {
            try service.register()

        } catch {

            /*
             macOS 有时会在后台项目审批过程中
             抛出 Operation not permitted，

             但此时 SMAppService 的状态
             其实已经变成：

             .requiresApproval
             或
             .enabled

             所以只有状态完全没有变化时，
             才真正把这个错误抛出去。
             */

            if service.status != .enabled
                &&
                service.status != .requiresApproval
            {
                throw error
            }
        }

        refreshStatus()
    }

    // MARK: - Uninstall

    func uninstall() throws {

        logger.info(
            "Unregistering charging helper daemon"
        )

        disconnect()

        try service.unregister()

        helperStatus =
            .notInstalled
    }

    // MARK: - Refresh Status

    func refreshStatus() {

        switch service.status {

        case .enabled:
            helperStatus =
                .installed

        case .requiresApproval:
            helperStatus =
                .requiresApproval

        default:
            helperStatus =
                .notInstalled
        }
    }

    // MARK: - XPC Error Callback

    /// NSXPC invokes its error block on an internal XPC queue.
    /// Build the outer callback in a nonisolated context so Swift 6
    /// does not require the XPC queue itself to be MainActor.
    nonisolated private static func makeProxyErrorHandler(
        manager: ChargingHelperManager,
        errorHandler:
            @escaping @Sendable
            (Error) -> Void
    ) -> @Sendable (Error) -> Void {

        return {
            [weak manager]
            error in

            Task {
                @MainActor in

                manager?
                    .logger
                    .error(
                        """
                        Charging helper \
                        proxy error: \
                        \(error.localizedDescription)
                        """
                    )

                errorHandler(
                    error
                )
            }
        }
    }

    // MARK: - Get Helper

    func getHelper(
        errorHandler:
            @escaping @Sendable
            (Error) -> Void
    ) -> ChargingHelperProtocol? {

        if connection == nil {
            connect()
        }

        guard
            let connection
        else {
            logger.error(
                """
                Charging helper connection \
                is unavailable
                """
            )

            return nil
        }

        let proxyErrorHandler =
            Self.makeProxyErrorHandler(
                manager: self,
                errorHandler: errorHandler
            )

        return
            connection
            .remoteObjectProxyWithErrorHandler(
                proxyErrorHandler
            )
            as? ChargingHelperProtocol

    }

    // MARK: - Connect

    private func connect() {

        // 已经有有效连接时不要重复创建。

        guard connection == nil else {
            return
        }

        logger.info(
            """
            Setting up XPC connection \
            to charging helper daemon
            """
        )

        let newConnection =
            NSXPCConnection(
                machServiceName:
                    Self.machServiceName,

                options:
                    .privileged
            )

        newConnection
            .remoteObjectInterface =
            NSXPCInterface(
                with:
                    ChargingHelperProtocol.self
            )

        // MARK: Invalidation

        newConnection
            .invalidationHandler =
        { [weak self, weak newConnection] in

            Task {
                @MainActor in

                guard
                    let self
                else {
                    return
                }

                self.logger.warning(
                    """
                    Charging helper XPC \
                    connection invalidated
                    """
                )

                /*
                 非常重要：

                 只允许“当前仍然是这条连接”的
                 invalidation 回调清空 connection。

                 例如：

                 旧连接 A
                 ↓
                 新连接 B 已建立
                 ↓
                 A 的 invalidation 晚到一步

                 旧版：
                 self.connection = nil

                 会把 B 也误清掉。

                 现在：
                 只有 self.connection === A
                 才清除。
                 */

                guard
                    let newConnection,
                    self.connection
                        === newConnection
                else {
                    self.logger.debug(
                        """
                        Ignoring stale \
                        invalidation callback
                        """
                    )

                    return
                }

                self.connection =
                    nil
            }
        }

        // MARK: Interruption

        newConnection
            .interruptionHandler =
        { [weak self, weak newConnection] in

            Task {
                @MainActor in

                guard
                    let self
                else {
                    return
                }

                guard
                    let newConnection,
                    self.connection
                        === newConnection
                else {
                    return
                }

                /*
                 这里和旧版本最大的不同：

                 interruption
                 ≠
                 invalidation

                 interruption 有可能只是：

                 - 系统瞬时调度
                 - helper 暂时不可响应
                 - sleep / wake
                 - XPC 临时通信中断

                 NSXPCConnection 有机会自己恢复。

                 所以这里绝对不要：

                 self.connection = nil

                 否则可能人为制造一次真正的
                 connection invalidation。
                 */

                self.logger.warning(
                    """
                    Charging helper XPC \
                    connection interrupted; \
                    keeping connection alive
                    """
                )
            }
        }

        // 先保存引用，
        // 再 resume。

        connection =
            newConnection

        newConnection.resume()

        logger.info(
            """
            Charging helper XPC \
            connection resumed
            """
        )
    }

    // MARK: - Disconnect

    func disconnect() {

        guard
            let currentConnection =
                connection
        else {
            return
        }

        logger.info(
            """
            Disconnecting charging helper \
            XPC connection
            """
        )

        /*
         先把本地引用清空，
         再 invalidate。

         这样 invalidationHandler
         回来以后会识别为旧连接，
         不会再次影响新的连接。
         */

        connection =
            nil

        currentConnection
            .invalidationHandler =
            nil

        currentConnection
            .interruptionHandler =
            nil

        currentConnection
            .invalidate()
    }
}
