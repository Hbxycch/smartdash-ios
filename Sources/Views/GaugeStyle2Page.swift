import SwiftUI

/// 仪表样式 2：三栏仪表（对应设计稿「仪表样式2-设计图-v3」）。
///  左列：电量 / 电压 / 电流 / 功率 / 电池温度；
///  中间：大弧码表 + 底部状态行（充放状态 · 航向 · 海拔）；
///  右列：控制器温度（≤50 正常绿 · 50~75 偏热黄 · >75 过热红，柱上带阈值刻度）。
///
/// 与样式 1（经典横排 + 地图）是两套完全不同的版式，独立成页便于继续调整。
/// 数据口径与样式 1 一致：实测优先，缺失按电池参数估算（BmsReadout）。
struct GaugeStyle2Page: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var service: BmsService
    @EnvironmentObject var location: LocationService

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 12) {
                leftColumn
                    .frame(width: min(geo.size.width * 0.22, 250))
                centerColumn
                rightColumn
                    .frame(width: min(geo.size.width * 0.22, 250))
            }
        }
        .padding(12)
    }

    private var snap: BmsSnapshot { service.snapshot }
    private var p: Palette { settings.palette }

    // MARK: - 左列

    private var leftColumn: some View {
        let r = BmsReadout(snapshot: snap, settings: settings)
        let fullV = BatteryProfile.packFullV(settings.chemistry, settings.series)
        let amp = snap.hasData ? abs(snap.current) : 0
        let kw = snap.hasData ? snap.powerW / 1000 : 0
        let battT = batteryTemp

        return VStack(spacing: 10) {
            // 电量：主指标
            VStack(spacing: 6) {
                Text("电量")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(p.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(snap.hasData || r.socEstimated
                         ? String(format: "%.0f", min(max(r.soc, 0), 100)) : "--")
                        .font(.system(size: 40, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(p.textPrimary)
                    Text("%")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(p.textSecondary)
                }
                StripeBar(ratio: r.soc / 100,
                          tint: p.accent, track: p.track)
                    .frame(height: 10)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(tile)

            tileMetric("电压",
                       value: r.totalVoltage > 0.5 ? String(format: "%.1f", r.totalVoltage) : "--",
                       unit: "V", ratio: r.totalVoltage > 0.5 ? r.totalVoltage / fullV : 0,
                       tint: p.accent)
            tileMetric("电流",
                       value: amp > 0.02 ? String(format: "%.1f", amp) : "--",
                       unit: "A", ratio: min(amp / 60, 1),
                       tint: p.accent)
            tileMetric("功率",
                       value: kw > 0.005 ? String(format: "%.2f", kw) : "--",
                       unit: "kW", ratio: min(kw / 4, 1),
                       tint: p.accent)

            // 电池温度：居中版式
            VStack(spacing: 4) {
                Text("电池温度")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(p.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(battT.map { String(format: "%.0f", $0) } ?? "--")
                        .font(.system(size: 22, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(p.textPrimary)
                    Text("°C")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(p.textSecondary)
                }
                ThinBar(ratio: battT.map { min(max($0 / 60, 0), 1) } ?? 0, tint: p.accent)
                    .frame(height: 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(tile)
            .frame(maxHeight: .infinity)
        }
    }

    /// 单个小指标卡：标签在左、数值在右、底部细进度条
    private func tileMetric(_ label: String, value: String, unit: String,
                            ratio: Double, tint: Color) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(p.textSecondary)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 21, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(p.textPrimary)
                    Text(unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(p.textSecondary)
                }
            }
            ThinBar(ratio: ratio, tint: tint)
                .frame(height: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tile)
        .frame(maxHeight: .infinity)
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(p.panel.opacity(settings.darkTheme ? 0.92 : 0.98))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(p.stroke, lineWidth: 1))
    }

    // MARK: - 中间：弧形码表 + 状态行

    private var centerColumn: some View {
        VStack(spacing: 4) {
            ArcDial(speed: location.speedKmh, palette: p)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) {
                Text(stateShort)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(stateColor)
                    .frame(width: 30, height: 30)
                    .background(Capsule().fill(stateColor.opacity(0.12)))
                    .overlay(Capsule().stroke(stateColor.opacity(0.32), lineWidth: 1))

                Text(stateText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(stateColor)

                Divider().frame(height: 14).overlay(p.stroke)

                Text(location.hasFix ? String(format: "航向 %.0f°", location.heading) : "航向 --")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(location.hasFix ? p.textSecondary : p.textSecondary.opacity(0.6))

                Divider().frame(height: 14).overlay(p.stroke)

                Text(location.hasFix ? String(format: "海拔 %.0f m", location.altitude) : "海拔 --")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(location.hasFix ? p.textSecondary : p.textSecondary.opacity(0.6))
            }
        }
    }

    private var stateShort: String {
        if readout.totalVoltage <= 0.5 { return "--" }
        return snap.charging ? "充" : (snap.current < -0.05 ? "放" : "静")
    }

    // 便捷取值：总电压（含单体兜底换算）有效才认为「有数据在跑」
    private var readout: BmsReadout { BmsReadout(snapshot: snap, settings: settings) }

    private var stateColor: Color {
        if readout.totalVoltage <= 0.5 { return p.textSecondary }
        if snap.charging { return p.accent }
        if snap.current < -0.05 { return p.ok }
        return p.textSecondary
    }

    private var stateText: String {
        if readout.totalVoltage <= 0.5 { return "--" }
        if snap.charging { return "充电中" }
        if snap.current < -0.05 { return "放电中" }
        return "静置"
    }

    // MARK: - 右列：控制器温度

    private var rightColumn: some View {
        let tier = ctrlTier
        let color = tier?.color ?? p.textSecondary
        let ratio: Double
        if let t = ctrlTemp { ratio = min(max(t / 100, 0), 1) } else { ratio = 0 }

        return VStack(spacing: 8) {
            Text("控制器温度")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(p.textSecondary)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(ctrlTemp.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(size: 46, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(color)
                Text("°C")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(p.textSecondary)
            }

            Text(tier?.text ?? "--")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.12)))
                .overlay(Capsule().stroke(color.opacity(0.32), lineWidth: 1))

            StripeBar(ratio: ratio,
                      tint: tier?.color ?? p.track,
                      track: p.track,
                      vertical: true,
                      marks: [(0.50, p.warn.opacity(0.5)), (0.75, p.danger.opacity(0.85))])
                .frame(width: 18)
                .frame(maxHeight: .infinity)
                .padding(.top, 8)

            Text("阈值 50 / 75 °C")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(p.textSecondary.opacity(0.7))
                .padding(.top, 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(tile)
    }

    // MARK: - 数据换算

    /// 控制器温度（MOS 温度），未上报时为 nil
    private var ctrlTemp: Double? {
        guard snap.hasData, snap.mosTemp.isFinite else { return nil }
        return snap.mosTemp
    }

    /// 电池温度：优先探头 1，蚂蚁协议只有温度数组时取最高探头
    private var batteryTemp: Double? {
        guard snap.hasData else { return nil }
        if snap.temp1.isFinite, snap.temp1 != 0 { return snap.temp1 }
        if snap.tempCount > 0 {
            let valid = snap.temps.prefix(snap.tempCount).filter { $0.isFinite }
            if let mx = valid.max() { return mx }
        }
        return snap.temp1.isFinite ? snap.temp1 : nil
    }

    /// 控制器温度三档：≤50 正常（绿）· 50~75 偏热（黄）· >75 过热（红）
    private var ctrlTier: (color: Color, text: String)? {
        guard let t = ctrlTemp else { return nil }
        if t > 75 { return (p.danger, "过热") }
        if t >= 50 { return (p.warn, "偏热") }
        return (p.ok, "正常")
    }
}

// MARK: - 条纹条

/// 条纹进度条（对应 Android 的 StripeBarView）：
/// 横向用于电量，纵向用于控制器温度；条纹比实心更贴近实车仪表的"刻度格"观感。
struct StripeBar: View {
    var ratio: Double
    var tint: Color
    var track: Color
    var vertical = false
    var marks: [(Double, Color)] = []   // 阈值刻度（0~1，自底向上）

    var body: some View {
        Canvas { ctx, size in
            let radius = min(size.width, size.height) / 2
            let clip = Path(roundedRect: CGRect(origin: .zero, size: size),
                            cornerRadius: radius, style: .continuous)
            let pitch: CGFloat = 11, thick: CGFloat = 7

            // 画条纹；region 限定条纹可见区段（底纹=整条，填充=按比例的下/左段）
            func stripes(_ color: Color, region: CGRect) {
                ctx.stroke(Path { path in
                    if vertical {
                        let boundary = region.minY          // 该线以下才算已填充
                        var y = size.height - pitch / 2
                        while y > -pitch {
                            let top = y - thick / 2
                            if top >= boundary - 0.5 {
                                path.move(to: CGPoint(x: thick / 2, y: y))
                                path.addLine(to: CGPoint(x: size.width - thick / 2, y: y))
                            } else if y + thick / 2 > boundary {
                                // 跨过分档线的最后一格：只画分档线以下的部分
                                path.move(to: CGPoint(x: thick / 2, y: boundary))
                                path.addLine(to: CGPoint(x: size.width - thick / 2, y: y))
                            }
                            y -= pitch
                        }
                    } else {
                        let right = region.maxX             // 该线以左才算已填充
                        var x = pitch / 2
                        while x < size.width + pitch {
                            if x <= right + 0.5 {
                                path.move(to: CGPoint(x: x, y: thick / 2))
                                path.addLine(to: CGPoint(x: x, y: size.height - thick / 2))
                            }
                            x += pitch
                        }
                    }
                }, with: .color(color), style: StrokeStyle(lineWidth: thick, lineCap: .round))
            }

            ctx.clip(to: clip)
            stripes(track, region: CGRect(origin: .zero, size: size))
            if ratio > 0.002 {
                let fillRegion = vertical
                    ? CGRect(x: 0, y: size.height * (1 - ratio), width: size.width, height: size.height * ratio)
                    : CGRect(x: 0, y: 0, width: size.width * ratio, height: size.height)
                stripes(tint, region: fillRegion)
            }

            // 阈值刻度（画在条纹之上，横向贯穿）
            for (pos, color) in marks {
                let y = size.height * (1 - pos)
                ctx.fill(Path(CGRect(x: 0, y: y - 1, width: size.width, height: 2)),
                         with: .color(color))
            }
        }
    }
}

/// 实心细进度条（电压 / 电流 / 功率 / 电池温度）
struct ThinBar: View {
    var ratio: Double
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.22))
                Capsule().fill(tint)
                    .frame(width: max(0, min(1, ratio)) * geo.size.width)
            }
        }
    }
}

// MARK: - 弧形码表

/// 速度弧表（对应 Android 的 ArcDialView）：220° 连续弧 + 外圈细刻度 + 弧头圆点 + 中央大数字。
struct ArcDial: View {
    var speed: Double
    var maxKmh: Double = 200
    var palette: Palette

    @State private var shown: Double = 0

    private let startDeg: Double = 160
    private let sweepDeg: Double = 220
    private let ticks = 22

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let k = min(size.width, size.height) / 264

            func point(_ deg: Double, radius: CGFloat) -> CGPoint {
                let a = CGFloat(deg) * .pi / 180
                let s = CGFloat(sin(Double(a))), cs = CGFloat(cos(Double(a)))
                return CGPoint(x: center.x + cs * radius, y: center.y + s * radius)
            }

            // 与 GaugeView 一致：采样点连折线画弧，规避 clockwise 在不同坐标系下的方向歧义
            func arcPath(_ radius: CGFloat, _ from: Double, _ to: Double) -> Path {
                var path = Path()
                let steps = max(8, Int(abs(to - from) / 1.5))
                for i in 0...steps {
                    let deg = from + (to - from) * Double(i) / Double(steps)
                    if i == 0 { path.move(to: point(deg, radius: radius)) }
                    else { path.addLine(to: point(deg, radius: radius)) }
                }
                return path
            }

            let rTick = CGFloat(112 * k)
            let rArc = CGFloat(102 * k)

            // 外圈细刻度
            var tickPath = Path()
            for i in 0...ticks {
                let deg = startDeg + Double(i) * (sweepDeg / Double(ticks))
                tickPath.move(to: point(deg, radius: rTick - 4.5 * k))
                tickPath.addLine(to: point(deg, radius: rTick + 4.5 * k))
            }
            ctx.stroke(tickPath, with: .color(palette.stroke),
                       style: StrokeStyle(lineWidth: 1.8 * k, lineCap: .round))

            // 轨道 + 进度弧
            ctx.stroke(arcPath(rArc, startDeg, startDeg + sweepDeg),
                       with: .color(palette.track),
                       style: StrokeStyle(lineWidth: 10 * k, lineCap: .round))

            let frac = max(0, min(1, shown / maxKmh))
            if frac > 0.001, shown.isFinite {
                ctx.stroke(arcPath(rArc, startDeg, startDeg + sweepDeg * frac),
                           with: .color(palette.accent),
                           style: StrokeStyle(lineWidth: 10 * k, lineCap: .round))

                let deg = startDeg + sweepDeg * frac
                let hub = point(deg, radius: rArc)
                ctx.stroke(Path(ellipseIn: CGRect(x: hub.x - 10 * k, y: hub.y - 10 * k,
                                                  width: 20 * k, height: 20 * k)),
                           with: .color(palette.accent.opacity(0.3)),
                           lineWidth: 2 * k)
                ctx.fill(Path(ellipseIn: CGRect(x: hub.x - 5 * k, y: hub.y - 5 * k,
                                                width: 10 * k, height: 10 * k)),
                         with: .color(palette.accent))
            }

            // 中央数字 + 单位
            let num = shown.isFinite && shown >= 0 ? String(format: "%.0f", shown) : "--"
            ctx.draw(Text(num)
                .font(.system(size: 92 * k, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundColor(palette.textPrimary),
                at: CGPoint(x: center.x, y: center.y + 4 * k))
            ctx.draw(Text("km/h")
                .font(.system(size: 12 * k, weight: .medium))
                .foregroundColor(palette.textSecondary),
                at: CGPoint(x: center.x, y: center.y + 52 * k))
        }
        .onAppear { shown = speed }
        .onChange(of: speed) { newValue in
            withAnimation(.easeOut(duration: 0.45)) { shown = newValue }
        }
    }
}
