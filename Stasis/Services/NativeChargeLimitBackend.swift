import Foundation
import os.log

enum NativeChargeLimitBackendError:
    LocalizedError
{
    case unsupportedSystem
    case frameworkUnavailable
    case clientClassUnavailable
    case clientInitializationFailed
    case selectorUnavailable(String)

    case operationFailed(
        operation: String,
        message: String?
    )

    var errorDescription:
        String?
    {
        switch self {

        case .unsupportedSystem:
            return
                """
                Native charge limit requires \
                macOS 26 or newer.
                """

        case .frameworkUnavailable:
            return
                """
                PowerUI.framework could \
                not be loaded.
                """

        case .clientClassUnavailable:
            return
                """
                PowerUISmartChargeClient \
                is unavailable.
                """

        case .clientInitializationFailed:
            return
                """
                PowerUISmartChargeClient \
                could not be initialized.
                """

        case .selectorUnavailable(
            let selector
        ):
            return
                """
                Required PowerUI selector \
                is unavailable: \(selector)
                """

        case .operationFailed(
            let operation,
            let message
        ):
            if let message {
                return
                    """
                    \(operation) failed: \
                    \(message)
                    """
            }

            return
                """
                \(operation) failed.
                """
        }
    }
}

@MainActor
final class NativeChargeLimitBackend {

    // MARK: - Constants

    private enum Constants {

        static let frameworkPath =
            """
            /System/Library/PrivateFrameworks/\
            PowerUI.framework
            """

        static let clientClassName =
            "PowerUISmartChargeClient"

        static let clientName =
            "Stasis"

        static let initSelector =
            "initWithClientName:"

        static let isSupportedSelector =
            "isMCLSupported"

        static let isEnabledSelector =
            "isMCLCurrentlyEnabled:"

        static let enableSelector =
            "enableMCL:"

        static let disableSelector =
            "disableMCL:"
    }

    // MARK: - Objective-C Function Types

    // isMCLSupported
    //
    // B16@0:8
    private typealias BoolNoArgumentMethod =
        @convention(c)
        (
            AnyObject,
            Selector
        ) -> Bool

    // isMCLCurrentlyEnabled:
    //
    // Q24@0:8^@16
    private typealias UIntErrorMethod =
        @convention(c)
        (
            AnyObject,
            Selector,
            AutoreleasingUnsafeMutablePointer<
                NSError?
            >?
        ) -> UInt

    // enableMCL:
    // disableMCL:
    //
    // B24@0:8^@16
    private typealias BoolErrorMethod =
        @convention(c)
        (
            AnyObject,
            Selector,
            AutoreleasingUnsafeMutablePointer<
                NSError?
            >?
        ) -> Bool

    // MARK: - State

    private var client:
        NSObject?

    private var frameworkLoaded =
        false

    // MARK: - Logger

    private let logger =
        Logger(
            subsystem:
                "com.srimanachanta.stasis",

            category:
                "NativeChargeLimitBackend"
        )

    // MARK: - Availability

    var isAvailable:
        Bool
    {
        guard
            #available(macOS 26.0, *)
        else {
            return false
        }

        do {

            let client =
                try getClient()

            return
                try isSupported(
                    client:
                        client
                )

        } catch {

            logger.warning(
                """
                Native MCL unavailable: \
                \(error.localizedDescription)
                """
            )

            return false
        }
    }

    // MARK: - Enable

    /// 确保 macOS Manual Charge Limit
    /// 已经初始化。
    ///
    /// 实机验证流程：
    ///
    /// No battery limits
    /// ↓
    /// enableMCL()
    /// ↓
    /// 系统建立默认 80%
    ///
    /// 注意：
    ///
    /// enableMCL 后系统状态可能不是
    /// 同步瞬间更新。
    ///
    /// 所以这里不能：
    ///
    /// enableMCL()
    /// ↓
    /// 马上查询
    /// ↓
    /// 如果还是 false 就判失败
    ///
    /// PowerUI 返回 success
    /// 就认为初始化请求成功。
    func ensureEnabled()
        throws
    {
        guard
            #available(macOS 26.0, *)
        else {
            throw
                NativeChargeLimitBackendError
                .unsupportedSystem
        }

        let client =
            try getClient()

        guard
            try isSupported(
                client:
                    client
            )
        else {
            throw
                NativeChargeLimitBackendError
                .operationFailed(
                    operation:
                        "isMCLSupported",

                    message:
                        """
                        Manual Charge Limit \
                        is not supported.
                        """
                )
        }

        // 如果 PowerUI 明确报告
        // MCL 已经开启，
        // 就不要重复 enable。
        //
        // 这样已经处于 75% 时，
        // 不会因为重复 enableMCL
        // 被系统重新碰到默认 80%。

        do {

            let currentlyEnabled =
                try isEnabled(
                    client:
                        client
                )

            if currentlyEnabled {

                logger.debug(
                    """
                    Native MCL is already \
                    enabled; enableMCL \
                    was not called
                    """
                )

                return
            }

        } catch {

            // 查询失败不应该直接阻止
            // enableMCL。
            //
            // 真正的初始化操作
            // 仍然可以继续尝试。

            logger.warning(
                """
                Could not reliably determine \
                current MCL state before \
                enable: \
                \(error.localizedDescription)
                """
            )
        }

        let selector =
            NSSelectorFromString(
                Constants
                    .enableSelector
            )

        guard
            client.responds(
                to:
                    selector
            )
        else {
            throw
                NativeChargeLimitBackendError
                .selectorUnavailable(
                    Constants
                        .enableSelector
                )
        }

        let implementation =
            client.method(
                for:
                    selector
            )

        let function =
            unsafeBitCast(
                implementation,

                to:
                    BoolErrorMethod
                    .self
            )

        var error:
            NSError?

        let success =
            function(
                client,
                selector,
                &error
            )

        guard success else {

            throw
                NativeChargeLimitBackendError
                .operationFailed(
                    operation:
                        "enableMCL",

                    message:
                        error?
                        .localizedDescription
                )
        }

        // 不立即要求：
        //
        // isMCLCurrentlyEnabled == true
        //
        // 因为系统建立 Manual Charge Limit
        // 存在异步过程。
        //
        // 下一步 root helper
        // 会直接写最终 target，
        // 并通知 powerd。

        logger.info(
            """
            Native MCL enable request \
            succeeded
            """
        )
    }

    // MARK: - Disable

    /// 完全解除系统 Manual Charge Limit。
    ///
    /// 非常重要：
    ///
    /// 不能写成：
    ///
    /// if !isMCLCurrentlyEnabled {
    ///     return
    /// }
    ///
    /// 因为我们的 M4 Pro 实机测试
    /// 曾经出现过：
    ///
    /// manualChargeLimit = 80
    ///
    /// 但：
    ///
    /// isMCLCurrentlyEnabled = 0
    ///
    /// 此时真正调用 disableMCL()
    /// 仍然可以正确得到：
    ///
    /// No battery level limits set
    ///
    /// 因此 disableMCL 本身
    /// 才是这里的权威操作。
    func disable()
        throws
    {
        guard
            #available(macOS 26.0, *)
        else {
            throw
                NativeChargeLimitBackendError
                .unsupportedSystem
        }

        let client =
            try getClient()

        guard
            try isSupported(
                client:
                    client
            )
        else {
            throw
                NativeChargeLimitBackendError
                .operationFailed(
                    operation:
                        "isMCLSupported",

                    message:
                        """
                        Manual Charge Limit \
                        is not supported.
                        """
                )
        }

        // 状态查询只用于日志。
        //
        // 无论返回 true 还是 false，
        // 我们都会真正调用 disableMCL。

        do {

            let currentlyEnabled =
                try isEnabled(
                    client:
                        client
                )

            logger.debug(
                """
                MCL state before disable: \
                \(currentlyEnabled)
                """
            )

        } catch {

            logger.warning(
                """
                Could not query MCL state \
                before disable: \
                \(error.localizedDescription)
                """
            )
        }

        let selector =
            NSSelectorFromString(
                Constants
                    .disableSelector
            )

        guard
            client.responds(
                to:
                    selector
            )
        else {
            throw
                NativeChargeLimitBackendError
                .selectorUnavailable(
                    Constants
                        .disableSelector
                )
        }

        let implementation =
            client.method(
                for:
                    selector
            )

        let function =
            unsafeBitCast(
                implementation,

                to:
                    BoolErrorMethod
                    .self
            )

        var error:
            NSError?

        let success =
            function(
                client,
                selector,
                &error
            )

        guard success else {

            throw
                NativeChargeLimitBackendError
                .operationFailed(
                    operation:
                        "disableMCL",

                    message:
                        error?
                        .localizedDescription
                )
        }

        logger.info(
            """
            Native MCL disable request \
            succeeded
            """
        )
    }

    // MARK: - Query

    /// 只用于状态观察。
    ///
    /// 不应该把这个值当作
    /// “系统一定有没有 manualChargeLimit”
    /// 的唯一事实来源。
    func isEnabled()
        throws
        -> Bool
    {
        guard
            #available(macOS 26.0, *)
        else {
            return false
        }

        let client =
            try getClient()

        return
            try isEnabled(
                client:
                    client
            )
    }

    // MARK: - Client

    private func getClient()
        throws
        -> NSObject
    {
        if let client {
            return client
        }

        guard
            #available(macOS 26.0, *)
        else {
            throw
                NativeChargeLimitBackendError
                .unsupportedSystem
        }

        try loadFrameworkIfNeeded()

        guard
            let clientType =
                NSClassFromString(
                    Constants
                        .clientClassName
                )
                as? NSObject.Type
        else {
            throw
                NativeChargeLimitBackendError
                .clientClassUnavailable
        }

        // Runtime dump 已经确认：
        //
        // PowerUISmartChargeClient
        //
        // 提供：
        //
        // initWithClientName:
        //
        // 当前 Swift 侧先建立对象，
        // 再发送真正 initializer。

        let baseObject =
            clientType.init()

        let selector =
            NSSelectorFromString(
                Constants
                    .initSelector
            )

        guard
            baseObject.responds(
                to:
                    selector
            )
        else {
            throw
                NativeChargeLimitBackendError
                .selectorUnavailable(
                    Constants
                        .initSelector
                )
        }

        guard
            let unmanagedResult =
                baseObject.perform(
                    selector,

                    with:
                        Constants
                        .clientName
                        as NSString
                )
        else {
            throw
                NativeChargeLimitBackendError
                .clientInitializationFailed
        }

        guard
            let initializedClient =
                unmanagedResult
                .takeUnretainedValue()
                as? NSObject
        else {
            throw
                NativeChargeLimitBackendError
                .clientInitializationFailed
        }

        client =
            initializedClient

        logger.info(
            """
            PowerUISmartChargeClient \
            initialized
            """
        )

        return
            initializedClient
    }

    // MARK: - Framework

    private func loadFrameworkIfNeeded()
        throws
    {
        if frameworkLoaded {
            return
        }

        // Class 已经存在，
        // 说明 PowerUI 已经加载。

        if NSClassFromString(
            Constants
                .clientClassName
        ) != nil
        {
            frameworkLoaded =
                true

            return
        }

        guard
            let bundle =
                Bundle(
                    path:
                        Constants
                        .frameworkPath
                )
        else {
            throw
                NativeChargeLimitBackendError
                .frameworkUnavailable
        }

        let loaded =
            bundle.load()

        guard
            loaded
            ||
            NSClassFromString(
                Constants
                    .clientClassName
            ) != nil
        else {
            throw
                NativeChargeLimitBackendError
                .frameworkUnavailable
        }

        frameworkLoaded =
            true

        logger.info(
            "PowerUI.framework loaded"
        )
    }

    // MARK: - Private Query Helpers

    private func isSupported(
        client:
            NSObject
    ) throws -> Bool {

        let selector =
            NSSelectorFromString(
                Constants
                    .isSupportedSelector
            )

        guard
            client.responds(
                to:
                    selector
            )
        else {
            throw
                NativeChargeLimitBackendError
                .selectorUnavailable(
                    Constants
                        .isSupportedSelector
                )
        }

        let implementation =
            client.method(
                for:
                    selector
            )

        let function =
            unsafeBitCast(
                implementation,

                to:
                    BoolNoArgumentMethod
                    .self
            )

        return
            function(
                client,
                selector
            )
    }

    private func isEnabled(
        client:
            NSObject
    ) throws -> Bool {

        let selector =
            NSSelectorFromString(
                Constants
                    .isEnabledSelector
            )

        guard
            client.responds(
                to:
                    selector
            )
        else {
            throw
                NativeChargeLimitBackendError
                .selectorUnavailable(
                    Constants
                        .isEnabledSelector
                )
        }

        let implementation =
            client.method(
                for:
                    selector
            )

        let function =
            unsafeBitCast(
                implementation,

                to:
                    UIntErrorMethod
                    .self
            )

        var error:
            NSError?

        let rawValue =
            function(
                client,
                selector,
                &error
            )

        if let error {

            throw
                NativeChargeLimitBackendError
                .operationFailed(
                    operation:
                        "isMCLCurrentlyEnabled",

                    message:
                        error
                        .localizedDescription
                )
        }

        return
            rawValue != 0
    }
}
