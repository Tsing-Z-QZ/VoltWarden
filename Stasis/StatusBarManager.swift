import AppKit
import Defaults
import SwiftUI

@MainActor
class StatusBarManager: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let viewModel: MenuViewModel
    private let popover = NSPopover()
    private var displayLocationObserver: Defaults.Observation?

    init(viewModel: MenuViewModel) {
        self.viewModel = viewModel
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        super.init()
        statusItem.length = Defaults[.batteryPercentageDisplayLocation] == .nextToIcon ? 79 : 46
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        setupPersistentHostingView()
        displayLocationObserver = Defaults.observe(.batteryPercentageDisplayLocation) { [weak self] change in
            Task { @MainActor [weak self] in
                self?.statusItem.length = change.newValue == .nextToIcon ? 79 : 46
            }
        }
    }

    func setPopoverContent<V: View>(_ view: V) {
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 390, height: 1)
        controller.view.layoutSubtreeIfNeeded()
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 390, height: controller.view.fittingSize.height)
    }

    private func setupPersistentHostingView() {
        guard let button = statusItem.button else { return }

        let rootView = StatusBarContentView(viewModel: viewModel)
        let hosting = PassthroughHostingView(rootView: rootView)

        button.subviews.forEach { $0.removeFromSuperview() }
        button.title = ""
        button.image = nil
        button.isBordered = false
        (button.cell as? NSButtonCell)?.highlightsBy = []
        (button.cell as? NSButtonCell)?.showsStateBy = []
        button.target = self
        button.action = #selector(togglePopover(_:))

        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: button.topAnchor, constant: 4),
            hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -4),
            hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 7),
            hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -7),
        ])
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        showPopover()
    }

    func showPopover() {
        guard !popover.isShown else { return }
        guard let button = statusItem.button else { return }
        viewModel.menuWillOpen()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(false)
    }

    func popoverDidClose(_ notification: Notification) {
        viewModel.menuDidClose()
    }
}

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct StatusBarContentView: View {
    let viewModel: MenuViewModel
    @Default(.batteryPercentageDisplayLocation) var percentageDisplayLocation
    @Default(.showBatteryStateInStatusIcon) var showState

    var body: some View {
        BatteryIndicatorView(
            batteryLevel: viewModel.displayPercentage,
            chargingMode: viewModel.chargingMode,
            powerSource: viewModel.powerSource,
            adapterConnected: viewModel.adapterConnected,
            isLowPowerModeEnabled: viewModel.isLowPowerModeEnabled,
            percentageDisplayLocation: percentageDisplayLocation,
            showState: showState
        )
        .fixedSize()
        .offset(y: -1)
    }
}
