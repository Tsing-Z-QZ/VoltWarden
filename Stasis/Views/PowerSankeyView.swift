import SwiftUI

struct PowerSankeyView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let powerSource: PowerSource
    let isCharging: Bool
    let batteryPower: Double
    let adapterPower: Double
    let systemPower: Double

    private enum Layout {
        static let nodeWidth: CGFloat = 82
        static let nodeHeight: CGFloat = 48
        static let viewHeight: CGFloat = 118
    }

    private var showsBatteryDestination: Bool {
        powerSource == .acAdapter && isCharging && batteryPower > 0.15
    }

    private var flowLayoutID: String {
        switch powerSource {
        case .battery: "battery"
        case .both: "both"
        case .acAdapter: showsBatteryDestination ? "adapterCharging" : "adapterOnly"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                animatedFlows
                    .id(flowLayoutID)
                    .transition(.opacity)

                HStack(spacing: 0) {
                    sourceNodes
                    Spacer(minLength: 80)
                    destinationNodes
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.36),
                value: flowLayoutID
            )
        }
        .frame(height: Layout.viewHeight)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var animatedFlows: some View {
        if reduceMotion {
            Canvas { context, size in
                drawFlows(context: context, size: size, dashPhase: 0)
            }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas(rendersAsynchronously: true) { context, size in
                    let phase = (timeline.date.timeIntervalSinceReferenceDate * 24).truncatingRemainder(dividingBy: 15)
                    drawFlows(context: context, size: size, dashPhase: phase)
                }
            }
        }
    }

    @ViewBuilder
    private var sourceNodes: some View {
        VStack(spacing: 12) {
            switch powerSource {
            case .acAdapter:
                FlowNode(
                    title: String(localized: "Power Adapter"),
                    icon: "powerplug.fill",
                    power: adapterPower,
                    tint: .cyan
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .both:
                FlowNode(
                    title: String(localized: "Power Adapter"),
                    icon: "powerplug.fill",
                    power: adapterPower,
                    tint: .cyan
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                FlowNode(
                    title: String(localized: "Battery"),
                    icon: "battery.75percent",
                    power: batteryPower,
                    tint: .orange
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .battery:
                FlowNode(
                    title: String(localized: "Battery"),
                    icon: "battery.75percent",
                    power: batteryPower,
                    tint: .orange
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: Layout.nodeWidth)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.36),
            value: flowLayoutID
        )
    }

    @ViewBuilder
    private var destinationNodes: some View {
        VStack(spacing: 12) {
            if showsBatteryDestination {
                FlowNode(
                    title: String(localized: "Battery"),
                    icon: "battery.100percent.bolt",
                    power: batteryPower,
                    tint: .green
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            FlowNode(
                title: "Mac",
                icon: "laptopcomputer",
                power: systemPower,
                tint: Color(red: 0.20, green: 0.66, blue: 0.95)
            )
        }
        .frame(width: Layout.nodeWidth)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.36),
            value: showsBatteryDestination
        )
    }

    private func drawFlows(
        context: GraphicsContext,
        size: CGSize,
        dashPhase: Double
    ) {
        let leftX = Layout.nodeWidth + 8
        let rightX = size.width - Layout.nodeWidth - 8
        let centerY = size.height / 2
        let topY = Layout.nodeHeight / 2
        let bottomY = size.height - Layout.nodeHeight / 2

        switch powerSource {
        case .acAdapter where showsBatteryDestination:
            drawFlow(
                context: context,
                from: CGPoint(x: leftX, y: centerY),
                to: CGPoint(x: rightX, y: topY),
                power: batteryPower,
                tint: .green,
                dashPhase: dashPhase
            )
            drawFlow(
                context: context,
                from: CGPoint(x: leftX, y: centerY),
                to: CGPoint(x: rightX, y: bottomY),
                power: systemPower,
                tint: .cyan,
                dashPhase: dashPhase
            )
        case .both:
            drawFlow(
                context: context,
                from: CGPoint(x: leftX, y: topY),
                to: CGPoint(x: rightX, y: centerY),
                power: adapterPower,
                tint: .cyan,
                dashPhase: dashPhase
            )
            drawFlow(
                context: context,
                from: CGPoint(x: leftX, y: bottomY),
                to: CGPoint(x: rightX, y: centerY),
                power: batteryPower,
                tint: .orange,
                dashPhase: dashPhase
            )
        case .battery:
            drawFlow(
                context: context,
                from: CGPoint(x: leftX, y: centerY),
                to: CGPoint(x: rightX, y: centerY),
                power: batteryPower,
                tint: .orange,
                dashPhase: dashPhase
            )
        case .acAdapter:
            drawFlow(
                context: context,
                from: CGPoint(x: leftX, y: centerY),
                to: CGPoint(x: rightX, y: centerY),
                power: adapterPower,
                tint: .cyan,
                dashPhase: dashPhase
            )
        }
    }

    private func drawFlow(
        context: GraphicsContext,
        from start: CGPoint,
        to end: CGPoint,
        power: Double,
        tint: Color,
        dashPhase: Double
    ) {
        let magnitude = max(abs(power), 0.1)
        let width = min(max(7 + CGFloat(magnitude.squareRoot()) * 2.4, 10), 30)
        let controlX = (start.x + end.x) / 2
        let centerPath = Path { path in
            path.move(to: start)
            path.addCurve(
                to: end,
                control1: CGPoint(x: controlX, y: start.y),
                control2: CGPoint(x: controlX, y: end.y)
            )
        }

        context.stroke(
            centerPath,
            with: .color(tint.opacity(0.20)),
            style: StrokeStyle(lineWidth: width, lineCap: .round)
        )
        context.stroke(
            centerPath,
            with: .color(tint.opacity(0.92)),
            style: StrokeStyle(
                lineWidth: 2.2,
                lineCap: .round,
                dash: [7, 8],
                dashPhase: -dashPhase
            )
        )
    }
}

private struct FlowNode: View {
    let title: String
    let icon: String
    let power: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)

            Text(String(format: "%.1f W", abs(power)))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 82, height: 48)
        .stasisGlass(cornerRadius: 13, tint: tint.opacity(0.10))
    }
}

#Preview {
    VStack(spacing: 24) {
        PowerSankeyView(
            powerSource: .acAdapter,
            isCharging: true,
            batteryPower: 15.5,
            adapterPower: 36,
            systemPower: 20.5
        )
        PowerSankeyView(
            powerSource: .both,
            isCharging: false,
            batteryPower: -32.9,
            adapterPower: 28.4,
            systemPower: 61.3
        )
    }
    .padding(20)
    .frame(width: 380)
}
