import SwiftUI

struct BatteryIndicatorView: View {
    let batteryLevel: Int
    let chargingMode: ChargingMode
    var powerSource: PowerSource = .battery
    var adapterConnected: Bool = false
    var isLowPowerModeEnabled: Bool = false
    var percentageDisplayLocation: PercentageDisplayLocation = .hidden
    var showState: Bool = false

    private var level: Int { min(100, max(0, batteryLevel)) }
    private var inside: Bool { percentageDisplayLocation == .insideIcon }
    // Three digits plus a state glyph cannot fit into the two-digit shell.
    private var iconWidth: CGFloat { inside && level == 100 ? 32 : 28 }
    private var bodyWidth: CGFloat { iconWidth * 30 / 34 }
    private var color: Color {
        if showState && level <= 20 { return .red }
        if isLowPowerModeEnabled { return .yellow }
        if !inside && showState && chargingMode == .charging { return .green }
        return .primary
    }
    private var stateSymbol: String? {
        guard showState else { return nil }
        switch chargingMode {
        case .charging: return "bolt.fill"
        case .pluggedIn: return "powerplug.fill"
        case .discharging: return adapterConnected ? "powerplug.fill" : nil
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if percentageDisplayLocation == .nextToIcon {
                Text("\(level)%").font(.system(size: 11)).monospacedDigit()
            }
            if inside {
                ZStack {
                    BatterySilhouette().fill(color.opacity(0.48))
                    Rectangle()
                        .fill(color)
                        .frame(width: bodyWidth * CGFloat(level) / 100, height: 13)
                        .frame(width: iconWidth, height: 13, alignment: .leading)
                        .mask(BatterySilhouette())
                    HStack(spacing: 1) {
                        Text("\(level)")
                            .font(.system(size: level == 100 ? 8.5 : 9.4, weight: .semibold))
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                            .blendMode(.destinationOut)
                        if let stateSymbol {
                            Image(systemName: stateSymbol)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 7, height: 7)
                                .blendMode(.destinationOut)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: true)
                    .foregroundStyle(color)
                    .frame(width: bodyWidth, height: 15)
                    .offset(y: -0.8)
                    .frame(width: iconWidth, height: 13, alignment: .leading)
                }
                .frame(width: iconWidth, height: 13)
                .compositingGroup()
                .clipShape(BatterySilhouette())
            } else {
                ZStack {
                    BatterySilhouette().fill(color.opacity(0.48))
                    Rectangle()
                        .fill(color)
                        .frame(width: bodyWidth * CGFloat(level) / 100, height: 13)
                        .frame(width: iconWidth, height: 13, alignment: .leading)
                        .mask(BatterySilhouette())
                    if let stateSymbol {
                        Image(systemName: stateSymbol)
                            .font(.system(size: 8, weight: .bold))
                            .blendMode(.destinationOut)
                            .offset(x: -1.5)
                    }
                }
                .frame(width: iconWidth, height: 13)
                .compositingGroup()
                .clipShape(BatterySilhouette())
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("电池 \(level)%")
        .accessibilityValue(chargingMode == .charging ? "正在充电" :
            (chargingMode == .pluggedIn ? "已接通电源" :
                (powerSource == .both ? "适配器与电池共同供电" : "电池供电")))
    }
}

/// A menu-bar-sized battery outline with the same soft body corners and
/// connected terminal silhouette as the system status icon.
private struct BatterySilhouette: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let sx = rect.width / 34
        let sy = rect.height / 14
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var path = Path()
        path.move(to: point(5, 0.3))
        path.addLine(to: point(25, 0.3))
        path.addQuadCurve(to: point(30, 4.5), control: point(30, 0.3))
        path.addLine(to: point(30, 4.9))
        path.addLine(to: point(32.1, 4.9))
        path.addQuadCurve(to: point(33.2, 6), control: point(33.2, 4.9))
        path.addLine(to: point(33.2, 8))
        path.addQuadCurve(to: point(32.1, 9.1), control: point(33.2, 9.1))
        path.addLine(to: point(30, 9.1))
        path.addQuadCurve(to: point(25, 13.7), control: point(30, 13.7))
        path.addLine(to: point(5, 13.7))
        path.addQuadCurve(to: point(0, 9.5), control: point(0, 13.7))
        path.addLine(to: point(0, 4.5))
        path.addQuadCurve(to: point(5, 0.3), control: point(0, 0.3))
        path.closeSubpath()
        return path
    }
}
