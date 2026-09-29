import Defaults
import SwiftUI

struct DashboardMenuView: View {

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion


    let viewModel: MenuViewModel
    let openSettings: () -> Void
    let quit: () -> Void

    @Default(.chargeLimit)
    private var chargeLimit

    @Default(.showPowerDistribution)
    private var showPowerDistribution

    @Default(.calibrationPhase)
    private var calibrationPhase

    @Default(.showPowerSource) private var showPowerSource
    @Default(.showTimeTillDischarge) private var showTime
    @Default(.showBatteryMode) private var showMode
    @Default(.showBatteryTemperature) private var showTemperature
    @Default(.showBatteryHealth) private var showHealth

    // 滑块拖动过程中只更新本地预览值。
    // 松手后才真正写入 Defaults，避免把 70 → 80 → 75
    // 之间的每一个中间值都提交给充电后端。
    @State private var chargeLimitDraft = ChargeLimitDraft()

    private var limitEditingEnabled: Bool {
        viewModel.manageChargingEnabled && !viewModel.chargeLimitOverrideActive && !calibrationActive
    }

    private var calibrationActive: Bool {
        calibrationPhase != .idle
    }

    // Top Up 开启以后，
    // Dashboard 上真正显示 100%。
    private var displayedChargeLimit: Int {
        if viewModel.chargeLimitOverrideActive {
            return 100
        }

        return chargeLimitDraft.isEditing
            ? Int(chargeLimitDraft.value.rounded())
            : chargeLimit
    }

    private var calibrationStatusText:
        String
    {
        switch calibrationPhase {

        case .idle:
            String(
                localized:
                    "Calibration Ready"
            )

        case .chargingToFull:
            String(
                localized:
                    "Calibration: Charging to 100%"
            )

        case .dischargingToTen:
            String(
                localized:
                    "Calibration: Discharging to 10%"
            )

        case .chargingToFullAgain:
            String(
                localized:
                    "Calibration: Recharging to 100%"
            )

        case .holdingAtFull:
            String(
                localized:
                    "Calibration: Holding at 100%"
            )

        case .returningToLimit:
            String(
                localized:
                    "Calibration: Returning to charge limit"
            )
        }
    }

    private var batteryColor:
        Color
    {
        switch viewModel.chargingMode {

        case .charging:
            return .green

        case .pluggedIn:
            return Color(
                red: 0.15,
                green: 0.67,
                blue: 0.58
            )

        case .discharging:
            if viewModel.powerSource == .both {
                return Color(red: 0.15, green: 0.67, blue: 0.58)
            }
            return viewModel.displayPercentage <= 20
                ? .red
                : .orange
        }
    }

    var body: some View {

        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 14) {
                    dashboardContent
                }
            } else {
                dashboardContent
            }
        }
        .padding(16)
        .frame(width: 390)
        .background {

            LinearGradient(
                colors: [
                    Color(
                        red: 0.08,
                        green: 0.62,
                        blue: 0.54
                    )
                    .opacity(0.12),

                    Color(
                        nsColor:
                            .windowBackgroundColor
                    )
                    .opacity(0.45),

                    Color(
                        red: 0.18,
                        green: 0.48,
                        blue: 0.86
                    )
                    .opacity(0.08),
                ],

                startPoint:
                    .topLeading,

                endPoint:
                    .bottomTrailing
            )
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.32),
            value: showPowerDistribution
        )
    }

    // MARK: - Content

    private var dashboardContent:
        some View
    {
        VStack(spacing: 14) {

            header

            chargeControls

            overviewGrid

            if showPowerDistribution {
                powerCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            BatteryRing(percentage: viewModel.displayPercentage, color: batteryColor)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text("Battery").font(.system(size: 17, weight: .semibold, design: .rounded))
                    StatusDot(color: batteryColor)
                }
                if showMode {
                    Text(viewModel.batteryModeText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: viewModel.batteryModeText)
                }
            }
            Spacer(minLength: 0)
            if showPowerSource {
                VStack(alignment: .trailing, spacing: 5) {
                    Image(systemName: viewModel.adapterConnected ? "powerplug.fill" : "battery.75percent")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(batteryColor)
                    Text(viewModel.powerSourceText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let specification = viewModel.adapterSpecificationText {
                        Text(specification)
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(batteryColor)
                            .help("当前连接协商的供电功率，不是实时功耗。")
                    }
                }
            }
        }
        .padding(14)
        .stasisGlass(cornerRadius: 18, tint: batteryColor.opacity(0.14))
    }

    private var overviewGrid: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if showHealth {
                MetricCard(icon: "heart.fill", title: String(localized: "Battery Health"),
                           value: viewModel.batteryHealthText, tint: .green)
                    .frame(width: 112)
            }
            if showTemperature {
                MetricCard(icon: "thermometer.medium", title: String(localized: "Battery Temperature"),
                           value: viewModel.batteryTemperatureText, tint: .orange)
                    .frame(width: 112)
            }
            if showTime {
                MetricCard(icon: "clock.fill", title: viewModel.timeRemainingTitle,
                           value: viewModel.timeRemainingText, tint: .blue)
                    .frame(width: 112)
                    .help(viewModel.timeRemainingHelp)
                    .accessibilityLabel(viewModel.timeRemainingTitle + " " + viewModel.timeRemainingText)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Charge Controls

    private var chargeControls:
        some View
    {
        VStack(spacing: 10) {

            HStack {

                Label(
                    "Charge limit",
                    systemImage:
                        "gauge.with.dots.needle.50percent"
                )
                .font(
                    .system(
                        size: 13,
                        weight:
                            .semibold
                    )
                )

                Spacer()

                Text(
                    "\(displayedChargeLimit)%"
                )
                .font(
                    .system(
                        size: 14,
                        weight:
                            .bold,
                        design:
                            .rounded
                    )
                )
                .monospacedDigit()
                .contentTransition(
                    .numericText()
                )
            }

            Slider(
                value: Binding(
                    get: { Double(displayedChargeLimit) },
                    set: { value in
                        guard limitEditingEnabled else { return }
                        if let limit = chargeLimitDraft.update(value) { chargeLimit = limit }
                    }
                ),
                in: 50...100, step: 1,
                onEditingChanged: { editing in
                    if editing {
                        chargeLimitDraft.begin(current: chargeLimit)
                    } else if let limit = chargeLimitDraft.finish(enabled: limitEditingEnabled), limit != chargeLimit {
                        chargeLimit = limit
                    }
                }
            )
            .tint(Color(red: 0.08, green: 0.64, blue: 0.55))
            .focusEffectDisabled()
            .disabled(!limitEditingEnabled)
            .accessibilityLabel("充电上限")
            .onChange(of: limitEditingEnabled) { _, enabled in
                if !enabled { chargeLimitDraft.cancel() }
            }
            .onDisappear { chargeLimitDraft.cancel() }

            // Top Up 开启期间，
            // 当前有效 Charge Limit 固定为 100。
            //
            // 不允许用户一边 Top Up
            // 一边拖 Slider，
            // 避免出现两个目标冲突。
            HStack(spacing: 10) {

                // MARK: Top Up

                ActionButton(
                    title: viewModel.chargeLimitOverrideActive ? "取消临时充满" : String(localized: "Top Up"),

                    icon:
                        "battery.100percent.bolt",

                    isActive:
                        viewModel
                        .chargeLimitOverrideActive,

                    tint:
                        .green,

                    isDisabled:
                        !viewModel
                            .manageChargingEnabled
                        ||
                        !viewModel
                            .adapterConnected
                        ||
                        calibrationActive,

                    action:
                        viewModel
                        .toggleChargeLimitOverride
                )

                // MARK: Calibration

                ActionButton(
                    title:
                        calibrationActive
                        ? String(
                            localized:
                                "Stop Calibration"
                        )
                        : String(
                            localized:
                                "Calibrate"
                        ),

                    icon:
                        "arrow.trianglehead.2.clockwise.rotate.90",

                    isActive:
                        calibrationActive,

                    tint:
                        .blue,

                    isDisabled: !calibrationActive && (!viewModel.manageChargingEnabled || !viewModel.adapterConnected),

                    action:
                        viewModel
                        .toggleCalibration
                )
            }

            // MARK: Status Text

            if calibrationActive {

                Label(
                    calibrationStatusText,
                    systemImage:
                        "clock.arrow.trianglehead.counterclockwise.rotate.90"
                )
                .font(.caption)
                .foregroundStyle(
                    .secondary
                )
                .transition(.opacity)
                .frame(
                    maxWidth:
                        .infinity,

                    alignment:
                        .leading
                )

            } else if
                viewModel
                    .chargeLimitOverrideActive
            {
                Text(
                    "Top Up 已开启，当前有效充电上限为 100%。"
                )
                .font(.caption)
                .foregroundStyle(
                    .secondary
                )
                .transition(.opacity)
                .frame(
                    maxWidth:
                        .infinity,

                    alignment:
                        .leading
                )

            } else if
                !viewModel
                    .manageChargingEnabled
            {
                Text(
                    "Enable charge management in Settings to apply the limit."
                )
                .font(.caption)
                .foregroundStyle(
                    .secondary
                )
                .transition(.opacity)
                .frame(
                    maxWidth:
                        .infinity,

                    alignment:
                        .leading
                )
            }
        }
        .padding(13)
        .stasisGlass(
            cornerRadius: 18,
            tint: .green.opacity(0.12)
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.28),
            value: calibrationActive
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.28),
            value: viewModel.chargeLimitOverrideActive
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.28),
            value: viewModel.manageChargingEnabled
        )
    }

    // MARK: - Power

    private var powerCard:
        some View
    {
        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            HStack {

                Label(
                    "Live Power",
                    systemImage:
                        "waveform.path.ecg"
                )
                .font(
                    .system(
                        size: 14,
                        weight:
                            .semibold,
                        design:
                            .rounded
                    )
                )

                Spacer()

                Text(
                    viewModel
                        .powerSourceText
                )
                .font(.caption)
                .foregroundStyle(
                    .secondary
                )
            }

            PowerSankeyView(
                powerSource:
                    viewModel
                    .powerSource,

                isCharging:
                    viewModel
                    .isCharging,

                batteryPower:
                    viewModel
                    .batteryPower,

                adapterPower:
                    viewModel
                    .adapterPower,

                systemPower:
                    viewModel
                    .systemPower
            )
        }
        .padding(14)
        .stasisGlass(
            cornerRadius: 18,
            tint: .cyan.opacity(0.12)
        )
    }

    // MARK: - Footer

    private var footer:
        some View
    {
        HStack(spacing: 8) {

            Button(
                action:
                    openSettings
            ) {
                Label(
                    "Settings",
                    systemImage:
                        "gearshape.fill"
                )
            }
            .buttonStyle(
                FooterButtonStyle()
            )
            .focusEffectDisabled()

            Spacer()

            Button(
                action:
                    quit
            ) {
                Label(
                    "Quit",
                    systemImage:
                        "power"
                )
            }
            .buttonStyle(
                FooterButtonStyle()
            )
            .focusEffectDisabled()
        }
        .font(
            .system(
                size: 12,
                weight:
                    .medium
            )
        )
    }
}

// MARK: - Battery Ring

private struct BatteryRing:
    View
{
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let percentage: Int
    let color: Color

    var body: some View {

        ZStack {

            Circle()
                .stroke(
                    Color
                        .primary
                        .opacity(0.08),

                    lineWidth:
                        8
                )

            Circle()
                .trim(
                    from: 0,

                    to:
                        min(
                            max(
                                Double(
                                    percentage
                                )
                                / 100,
                                0
                            ),
                            1
                        )
                )
                .stroke(
                    AngularGradient(
                        colors: [
                            color
                                .opacity(0.55),
                            color,
                        ],

                        center:
                            .center
                    ),

                    style:
                        StrokeStyle(
                            lineWidth:
                                8,

                            lineCap:
                                .round
                        )
                )
                .rotationEffect(
                    .degrees(-90)
                )

            VStack(spacing: -2) {

                Text(
                    "\(percentage)"
                )
                .font(
                    .system(
                        size: 27,
                        weight:
                            .bold,
                        design:
                            .rounded
                    )
                )
                .monospacedDigit()

                Text("%")
                    .font(
                        .system(
                            size: 11,
                            weight:
                                .semibold,
                            design:
                                .rounded
                        )
                    )
                    .foregroundStyle(
                        .secondary
                    )
            }
        }
        .frame(
            width: 78,
            height: 78
        )
        .animation(
            reduceMotion ? nil : .smooth(
                duration:
                    0.35
            ),

            value:
                percentage
        )
    }
}

// MARK: - Status Dot

private struct StatusDot:
    View
{
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color

    var body: some View {

        Circle()
            .fill(color)
            .frame(
                width: 7,
                height: 7
            )
            .shadow(
                color:
                    color
                    .opacity(0.45),

                radius:
                    3
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.3),
                value: color
            )
    }
}

// MARK: - Metric Card

private struct MetricCard:
    View
{
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {

        VStack(spacing: 7) {

            Image(
                systemName:
                    icon
            )
            .font(
                .system(
                    size: 14,
                    weight:
                        .semibold
                )
            )
            .foregroundStyle(
                tint
            )
            .frame(
                width: 28,
                height: 28
            )
            .background(
                tint
                    .opacity(0.12),

                in:
                    Circle()
            )

            Text(value)
                .font(
                    .system(
                        size: 14,
                        weight:
                            .bold,
                        design:
                            .rounded
                    )
                )
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(
                    0.75
                )
                .contentTransition(.opacity)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.25),
                    value: value
                )

            Text(title)
                .font(
                    .system(
                        size: 10.5,
                        weight:
                            .medium
                    )
                )
                .foregroundStyle(
                    .secondary
                )
                .lineLimit(1)
                .minimumScaleFactor(
                    0.72
                )
        }
        .padding(
            .vertical,
            10
        )
        .frame(
            maxWidth:
                .infinity,

            minHeight:
                82
        )
        .stasisGlass(
            cornerRadius: 15,
            tint: tint.opacity(0.10)
        )
    }
}

// MARK: - Action Button

private struct ActionButton:
    View
{
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let icon: String
    let isActive: Bool
    let tint: Color
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {

        Button(
            action:
                action
        ) {

            HStack(spacing: 8) {

                Image(
                    systemName:
                        icon
                )
                .font(
                    .system(
                        size: 14,
                        weight:
                            .semibold
                    )
                )

                Text(title)
                    .font(
                        .system(
                            size: 12,
                            weight:
                                .semibold
                        )
                    )
                    .lineLimit(1)

                Spacer(
                    minLength:
                        0
                )

                if isActive {

                    Image(
                        systemName:
                            "checkmark.circle.fill"
                    )
                }
            }
            .foregroundStyle(
                isActive
                ? .white
                : .primary
            )
            .padding(
                .horizontal,
                11
            )
            .frame(
                maxWidth:
                    .infinity,

                minHeight:
                    38
            )
            .background(

                RoundedRectangle(
                    cornerRadius:
                        11,

                    style:
                        .continuous
                )
                .fill(
                    isActive
                    ? tint
                        .opacity(0.88)
                    : Color.clear
                )
            )
            .stasisGlass(
                cornerRadius:
                    11,

                tint:
                    isActive
                    ? tint
                        .opacity(0.16)
                    : nil,

                interactive:
                    true
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.26),
                value: isActive
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(
            isDisabled
        )
        .opacity(
            isDisabled
            ? 0.45
            : 1
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.26),
            value: isDisabled
        )
    }
}

// MARK: - Footer Style

private struct FooterButtonStyle:
    ButtonStyle
{
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(
        configuration:
            Configuration
    ) -> some View {

        configuration
            .label
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .padding(
                .horizontal,
                9
            )
            .padding(
                .vertical,
                6
            )
            .background(

                RoundedRectangle(
                    cornerRadius:
                        8,

                    style:
                        .continuous
                )
                .fill(
                    configuration
                        .isPressed
                    ? Color
                        .primary
                        .opacity(0.18)
                    : isHovered
                        ? Color.primary.opacity(0.12)
                        : .clear
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(isHovered ? 0.08 : 0),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.16),
                value: isHovered
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}
