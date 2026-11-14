import Foundation
import SwiftUI

/// 0-200 km/h 弧形速度表盘（自绘）。
/// 几何与 Android 版一致：135° 起、扫角 215°、10 段 ×20 km/h，
/// 180-200 为红区且常亮；指针位置用一个亮点表示，中央是大字车速。
struct GaugeView: View {
    var speed: Double
    var maxSpeed: Double = 200

    @EnvironmentObject var settings: AppSettings
    @State private var shown: Double = 0

    private let startDeg: Double = 135
    private let sweepDeg: Double = 215
    private let segmentCount = 10

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let p = settings.palette
            ZStack {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let r = min(size.width, size.height) / 2 - max(10, side * 0.045)
                    drawTrack(&ctx, center: c, radius: r, palette: p)
                    drawSegments(&ctx, center: c, radius: r, palette: p)
                    drawTicks(&ctx, center: c, radius: r, palette: p, side: side)
                    drawPointer(&ctx, center: c, radius: r, palette: p)
                }
                VStack(spacing: 0) {
                    Text("\(Int(shown.rounded()))")
                        .font(.system(size: side * 0.26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(p.textPrimary)
                    Text("km/h")
                        .font(.system(size: side * 0.055, weight: .medium))
                        .foregroundColor(p.textSecondary)
                }
                .offset(y: side * 0.02)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { shown = speed }
        .onChange(of: speed) { newValue in
            withAnimation(.easeOut(duration: 0.45)) { shown = newValue }
        }
    }

    // MARK: - 绘制

    private func angle(_ deg: Double) -> Double { deg * .pi / 180 }

    /// 用采样点连折线画弧，规避 clockwise 方向在不同坐标系下的歧义
    private func arcPath(_ center: CGPoint, _ radius: CGFloat,
                         from a0: Double, to a1: Double) -> Path {
        var path = Path()
        let steps = max(8, Int(abs(a1 - a0) / 1.5))
        for i in 0...steps {
            let t = a0 + (a1 - a0) * Double(i) / Double(steps)
            let rad = angle(t)
            let pt = CGPoint(x: center.x + radius * CGFloat(cos(rad)),
                             y: center.y + radius * CGFloat(sin(rad)))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }

    private func drawTrack(_ ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, palette p: Palette) {
        let width = max(10, radius * 0.15)
        ctx.stroke(arcPath(center, radius, from: startDeg, to: startDeg + sweepDeg),
                   with: .color(p.track),
                   style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func drawSegments(_ ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, palette p: Palette) {
        let width = max(10, radius * 0.15)
        let gap: Double = 2.2
        let per = sweepDeg / Double(segmentCount)

        for i in 0..<segmentCount {
            let a0 = startDeg + Double(i) * per + gap / 2
            let a1 = startDeg + Double(i + 1) * per - gap / 2
            let segStartSpeed = Double(i) * maxSpeed / Double(segmentCount)
            let isRed = segStartSpeed >= 180

            let color: Color
            if isRed {
                color = p.redZone                                  // 红区常亮
            } else if shown >= segStartSpeed {
                color = p.accent
            } else {
                color = p.track.opacity(p.dark ? 0.7 : 1)
            }

            ctx.stroke(arcPath(center, radius, from: a0, to: a1),
                       with: .color(color),
                       style: StrokeStyle(lineWidth: width, lineCap: .butt))
        }
    }

    private func drawTicks(_ ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat,
                           palette p: Palette, side: CGFloat) {
        let width = max(10, radius * 0.15)
        let tickOuter = radius - width * 0.75
        let fontSize = max(8, side * 0.042)

        for v in stride(from: 0, through: Int(maxSpeed), by: 10) {
            let t = Double(v) / maxSpeed
            let deg = startDeg + sweepDeg * t
            let rad = angle(deg)
            let major = v % 20 == 0

            let len: CGFloat = major ? max(6, side * 0.030) : max(3, side * 0.016)
            let p1 = CGPoint(x: center.x + tickOuter * CGFloat(cos(rad)),
                             y: center.y + tickOuter * CGFloat(sin(rad)))
            let p2 = CGPoint(x: center.x + (tickOuter - len) * CGFloat(cos(rad)),
                             y: center.y + (tickOuter - len) * CGFloat(sin(rad)))
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            ctx.stroke(path,
                       with: .color(major ? p.textSecondary : p.textSecondary.opacity(0.35)),
                       style: StrokeStyle(lineWidth: major ? 1.8 : 1, lineCap: .round))

            // 数字标签每 40 km/h 一个，避免表盘太密显得乱
            if v % 40 == 0 {
                let labelR = tickOuter - len - fontSize * 0.95
                let lp = CGPoint(x: center.x + labelR * CGFloat(cos(rad)),
                                 y: center.y + labelR * CGFloat(sin(rad)))
                let text = Text("\(v)")
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundColor(p.textSecondary)
                ctx.draw(text, at: lp)
            }
        }
    }

    /// 当前速度位置的高亮圆点
    private func drawPointer(_ ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, palette p: Palette) {
        let t = min(1, max(0, shown / maxSpeed))
        let deg = startDeg + sweepDeg * t
        let rad = angle(deg)
        let width = max(10, radius * 0.15)
        let pt = CGPoint(x: center.x + radius * CGFloat(cos(rad)),
                         y: center.y + radius * CGFloat(sin(rad)))
        let dotR = width * 0.42
        let rect = CGRect(x: pt.x - dotR, y: pt.y - dotR, width: dotR * 2, height: dotR * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color(p.textPrimary))
        let inner = rect.insetBy(dx: dotR * 0.45, dy: dotR * 0.45)
        ctx.fill(Path(ellipseIn: inner), with: .color(t >= 0.9 ? p.redZone : p.accent))
    }
}
