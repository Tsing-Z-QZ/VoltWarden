import AppKit
import Combine
import Defaults
import IOKit
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var settingsContent: SettingsView?
    private var showDashboardWhenReady = false
    private var statusBarManager: StatusBarManager!
    private var batteryService: BatteryService!
    private var viewModel: MenuViewModel!
    private var menuBuilder: MenuBuilder!
    private var chargeManager: ChargeManager!
    private var settingsWindowController: SettingsWindowController!
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Exit the app immediately if the device doesn't have a battery
        let batteryIOService = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard batteryIOService != 0 else {
            NSApplication.shared.terminate(nil)
            return
        }
        IOObjectRelease(batteryIOService)

        Task {
            await setupServices()
            setupMenu()
            if showDashboardWhenReady { showDashboard() }
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
            ControlDiagnostics.shared.record("APP", "started build=\(build) pid=\(ProcessInfo.processInfo.processIdentifier) path=\(Bundle.main.bundlePath)")
            runControlVerificationIfRequested()
            showDashboardPreviewIfRequested()
            #if DEBUG
            if ProcessInfo.processInfo.environment["STASIS_TEST_TOPUP"] == "1" {
                viewModel.toggleChargeLimitOverride()
            }
            #endif
            requestNotificationPermissions()
        }
    }

    func showDashboard() {
        guard let statusBarManager else {
            showDashboardWhenReady = true
            return
        }
        showDashboardWhenReady = false
        statusBarManager.showPopover()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showDashboard() }
        return false
    }

    private func runControlVerificationIfRequested() {
        #if DEBUG
        guard let specification = ProcessInfo.processInfo.environment["STASIS_TEST_LIMITS"] else { return }
        let targets = specification.split(separator: ",").compactMap { Int($0) }
        guard !targets.isEmpty, targets.allSatisfy({ (50...100).contains($0) }) else { return }
        let dwell = max(2, min(60, Int(ProcessInfo.processInfo.environment["STASIS_TEST_DWELL"] ?? "20") ?? 20))
        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<30 {
                if self.batteryService.hasObservedIOKitState { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard self.batteryService.controlState.adapterConnected,
                  Defaults[.manageCharging] else {
                ControlDiagnostics.shared.record("TEST_ABORT", "requires connected adapter and enabled charging management")
                return
            }
            let originalLimit = Defaults[.chargeLimit]
            defer {
                Defaults[.chargeLimit] = originalLimit
                ControlDiagnostics.shared.record("TEST_END", "restored limit=\(originalLimit)")
            }
            ControlDiagnostics.shared.record("TEST_START", "targets=\(targets) dwell=\(dwell)s original=\(originalLimit)")
            if ProcessInfo.processInfo.environment["STASIS_TEST_RAPID"] == "1" {
                for target in [75, 85, 75, 85] {
                    Defaults[.chargeLimit] = target
                    ControlDiagnostics.shared.record("TEST_SET", "rapid target=\(target)")
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            for target in targets {
                guard !Task.isCancelled else { return }
                Defaults[.chargeLimit] = target
                ControlDiagnostics.shared.record("TEST_SET", "target=\(target)")
                for second in 0..<dwell {
                    try? await Task.sleep(for: .seconds(1))
                    if second == 0 || second == dwell - 1 {
                        let snapshot = await self.batteryService.diagnosticControlStatus()
                        ControlDiagnostics.shared.record("HELPER", snapshot)
                    }
                }
            }
        }
        #endif
    }

    private func setupServices() async {
        batteryService = BatteryService()
        await batteryService.loadCapabilities()
        chargeManager = ChargeManager(batteryService: batteryService)
        let helperManager = ChargingHelperManager.shared
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        let registeredBuild = UserDefaults.standard.string(forKey: "chargingHelperRegisteredBuild")
        if UserDefaults.standard.bool(forKey: "manageCharging") && registeredBuild != currentBuild {
            for _ in 0..<30 where !batteryService.hasObservedIOKitState {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let helperStatus = UserDefaults.standard.bool(forKey: "manageCharging") &&
            registeredBuild != currentBuild
            ? await batteryService.diagnosticControlStatus() : nil
        if let helperStatus, helperManager.isInstalled,
           !helperStatus.hasPrefix("helper status error:") {
            // An in-place app update keeps the existing ServiceManagement
            // registration valid. Do not revoke its approval just because the
            // app build number changed (for example, for an icon-only update).
            UserDefaults.standard.set(currentBuild, forKey: "chargingHelperRegisteredBuild")
            ControlDiagnostics.shared.record("HELPER_REUSE", "build=\(currentBuild) status=\(helperStatus)")
        } else if ChargingHelperRefreshPolicy.shouldRefresh(
            manageCharging: UserDefaults.standard.bool(forKey: "manageCharging"),
            hasObservedPowerSource: batteryService.hasObservedIOKitState,
            adapterConnected: batteryService.controlState.adapterConnected,
            registeredBuild: registeredBuild,
            currentBuild: currentBuild
        ) {
            do {
                // Replacing the app bundle can invalidate ServiceManagement's
                // bookmark to an older build. Off AC, no hardware command is
                // needed before unregistering that stale service.
                if helperManager.isRegistered { try helperManager.uninstall() }
                try helperManager.install()
                let status = await batteryService.diagnosticControlStatus()
                guard helperManager.isInstalled,
                      !status.hasPrefix("helper status error:") else {
                    throw NSError(domain: "StasisChargingHelperRefresh", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: status])
                }
                UserDefaults.standard.set(currentBuild, forKey: "chargingHelperRegisteredBuild")
                UserDefaults.standard.set(true, forKey: "staticChargingHelperV1")
                ControlDiagnostics.shared.record("HELPER_REFRESH", "registered build=\(currentBuild) status=\(status)")
            } catch {
                ControlDiagnostics.shared.record("HELPER_REFRESH_ERROR", error.localizedDescription)
            }
        } else if UserDefaults.standard.bool(forKey: "manageCharging"),
                  registeredBuild != currentBuild, batteryService.controlState.adapterConnected {
            ControlDiagnostics.shared.record("HELPER_REFRESH_DEFERRED", "unplug before re-registering build=\(currentBuild)")
        }
        viewModel = MenuViewModel(
            batteryService: batteryService,
            chargeManager: chargeManager
        )
        settingsWindowController = SettingsWindowController(
            capabilities: batteryService.deviceCapabilities,
            chargeManager: chargeManager
        )
        settingsContent = SettingsView(
            capabilities: batteryService.deviceCapabilities,
            chargeManager: chargeManager
        )
        menuBuilder = MenuBuilder(
            viewModel: viewModel,
            settingsWindowController: settingsWindowController
        )
        statusBarManager = StatusBarManager(viewModel: viewModel)
    }

    private func setupMenu() {
        statusBarManager.setPopoverContent(menuBuilder.dashboardView())
    }

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    private func showDashboardPreviewIfRequested() {
        guard ProcessInfo.processInfo.environment["STASIS_UI_PREVIEW"] == "1" else {
            return
        }

        viewModel.menuWillOpen()

        let previewContent = VStack(spacing: 12) {
            HStack {
                Text("Menu Bar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                StatusBarContentView(viewModel: viewModel)
            }
            .padding(.horizontal, 16)

            menuBuilder.dashboardView()
        }
        let hostingView = NSHostingView(rootView: previewContent)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stasis UI Preview"
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        previewWindow = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
