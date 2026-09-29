import SwiftUI

private struct StasisGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content.stasisGlassSurface(cornerRadius: cornerRadius, tint: tint, interactive: interactive)
        }
    }
}

extension View {
    func stasisGlass(cornerRadius: CGFloat = 16, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(StasisGlassModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    @ViewBuilder
    fileprivate func stasisGlassSurface(
        cornerRadius: CGFloat = 16,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )

        if #available(macOS 26.0, *) {
            let glass = Glass.regular
                .tint(tint)
                .interactive(interactive)

            self
                .glassEffect(
                    glass,
                    in: shape
                )
                // 很轻的高光边缘：让卡片像一整块液态玻璃，
                // 但不做成明显的描边/蓝框。
                .overlay {
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.22),
                                    Color.white.opacity(0.07),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.65
                        )
                        .allowsHitTesting(false)
                }
                .background {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.045),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .allowsHitTesting(false)
                }
                .shadow(
                    color: Color.black.opacity(0.07),
                    radius: 10,
                    y: 4
                )
        } else {
            self
                .background(
                    .thinMaterial,
                    in: shape
                )
                .overlay {
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.18),
                                    Color.primary.opacity(0.05),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.7
                        )
                        .allowsHitTesting(false)
                }
                .shadow(
                    color: Color.black.opacity(0.06),
                    radius: 8,
                    y: 3
                )
        }
    }
}
