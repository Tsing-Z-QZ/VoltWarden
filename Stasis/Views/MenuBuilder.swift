import SwiftUI

@MainActor
class MenuBuilder {
    private let viewModel: MenuViewModel
    private let settingsWindowController: SettingsWindowController

    init(
        viewModel: MenuViewModel,
        settingsWindowController: SettingsWindowController
    ) {
        self.viewModel = viewModel
        self.settingsWindowController = settingsWindowController
    }

    func dashboardView() -> DashboardMenuView {
        DashboardMenuView(
            viewModel: viewModel,
            openSettings: { [weak self] in
                self?.settingsWindowController.showSettings()
            },
            quit: { [weak self] in
                self?.viewModel.quit()
            }
        )
    }

}
