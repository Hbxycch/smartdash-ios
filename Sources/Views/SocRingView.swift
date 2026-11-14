import SwiftUI

/// 圆形电量环：外圈进度弧（12 点起顺时针）+ 圆心百分比数字。
///
/// 与安卓的 SocRingView 同一设计语言：
/// · 弧色随电量分档 —— <15% 红、<35% 琥珀、其余青→绿渐变；
/// · 无数据时显示 "--" 且不画弧；
/// · 尺寸自适应：仪表角标（64pt）、电池卡（72pt）、电池页主视觉（96pt）共用。
struct SocRingView: View {
    let soc: Double?
    var size: CGFloat = 96
    var palette: Palette

    @State private var shown: Double = 0

    var body: some View {
        let p = palette
        let has = soc != nil && soc! >= 0 && soc! <= 100
        let pct = has ? min(100, max(0, soc!)) : 0
        let stroke = max(4, size * 0.085)

        return ZStack {
            Circle()
                .stroke(p.track, lineWidth: stroke)
            Circle()
                .trim(from: 0, to: shown / 100)
                .stroke(
                    AngularGradient(
                        stops: [
                            .init(color: arcStart(pct), location: 0),
                            .init(color: arcStart(pct), location: 0.72),
                            .init(color: arcEnd(pct), location: 1),
                        ],
                        center: .center),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(has ? 1 : 0)
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(has ? String(format: "%.0f", pct) : "--")
                        .font(.system(size: size * 0.30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(has ? textColor(pct) : p.textSecondary)
                    Text("%")
                        .font(.system(size: size * 0.14, weight: .medium))
                        .foregroundColor(has ? arcEnd(pct) : p.textSecondary)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { shown = pct }
        .onChange(of: soc ?? -1) { _ in withAnimation(.easeOut(duration: 0.4)) { shown = pct } }
    }

    private func arcStart(_ pct: Double) -> Color {
        let p = palette
        if pct < 15 { return p.danger }
        if pct < 35 { return p.warn }
        return p.accent
    }

    private func arcEnd(_ pct: Double) -> Color {
        let p = palette
        if pct < 15 { return p.danger }
        if pct < 35 { return p.warn }
        return p.ok
    }

    private func textColor(_ pct: Double) -> Color {
        let p = palette
        if pct < 15 { return p.danger }
        if pct < 35 { return p.warn }
        return p.textPrimary
    }
}
