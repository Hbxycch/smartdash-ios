import SwiftUI

/// 仪表样式 3：特斯拉卡片风（对应 Android view_tab_dashboard3）。
///  近黑底 + 大圆角卡片 + 卡片留隙：
///  左侧一张速度大卡（弧表 + 两侧对称小圆表），右列电池 / 控制器两张独立卡片，底部状态条。
///
/// 与样式 2（经典）的区别只在「排布语言」：样式 2 是三栏同底、靠分隔线分区；
/// 样式 3 把每块信息装进各自卡片，靠留白与卡片边界分组，更接近车机桌面的观感。
/// 数据口径与样式 1/2 完全一致（实测优先，缺失按化学体系 × 串数估算并标注）。
struct GaugeStyle3Page: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var service: BmsService
    @EnvironmentObject var location: LocationService
    @EnvironmentObject var ctrl: ZhikeService

    var body: some View {
        GeometryReader { geo in
            let rightWidth = min(geo.size.width * 0.32, 340)

            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    speedCard
                    VStack(spacing: 12) {
                        batteryCard
                        controllerCard
                    }
                    .frame(width: rightWidth)
                }
                .frame(maxHeight: .infinity)

                footBar
            }
            .frame(height: geo.size.height)
        }
        .padding(12)
    }

    private var snap: BmsSnapshot { service.snapshot }
    private var p: Palette { settings.palette }
    private var readout: BmsReadout { BmsReadout(snapshot: snap, settings: settings) }
    private var fullV: Double { BatteryProfile.packFullV(settings.chemistry, settings.series) }

    private var dash3card: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(p.panel.opacity(settings.darkTheme ? 0.92 : 0.98))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(p.stroke, lineWidth: 1))
    }

    private func cardHeader(_ title: String, chip: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .tracking(1.2)
                .foregroundColor(p.textSecondary)
            Spacer()
            Text(chip)
                .font(.system(size: 11))
                .foregroundColor(p.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(p.panelAlt))
                .overlay(Capsule().stroke(p.stroke, lineWidth: 1))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: - 左：车速大卡

    private var speedCard: some View {
        VStack(spacing: 4) {
            cardHeader("车速", chip: "GPS")

            ZStack {
                ArcDial(speed: location.speedKmh, palette: p)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    MiniRing(title: "电压",
                             value: totalV > 0.5 ? String(format: "%.1f", totalV) : "--",
                             unit: "V", ratio: totalV > 0.5 ? totalV / max(1, fullV) : 0,
                             tint: p.accent, palette: p)
                        .frame(width: 106, height: 106)
                    Spacer()
                    MiniRing(title: "转速",
                             value: hasRpm ? String(format: "%.0f", zhikeRpm) : "--",
                             unit: "rpm",
                             ratio: hasRpm ? min(max(zhikeRpm / 6000, 0), 1) : 0,
                             tint: zhikeRpm > 0.5 ? p.ok : p.accent,
                             palette: p)
                        .frame(width: 106, height: 106)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }

            // 卡脚：充放状态 + 里程
            HStack(spacing: 9) {
                Text(stateShort)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(stateColor)
                    .frame(width: 30, height: 30)
                    .background(Capsule().fill(stateColor.opacity(0.12)))
                    .overlay(Capsule().stroke(stateColor.opacity(0.32), lineWidth: 1))

                Text(stateText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(stateColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Rectangle().fill(p.stroke).frame(width: 1, height: 14)

                Text(Odometer.shared.summaryText)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundColor(p.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
            }
            .frame(height: 34)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(dash3card)
    }

    // MARK: - 右：电池卡

    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("电池", chip: settings.vendor.label)

            // SOC 主读数 + 右侧容量说明
            HStack(alignment: .bottom, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(socValid ? String(format: "%.0f", min(max(readout.soc, 0), 100)) : "--")
                        .font(.system(size: 48, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(p.textPrimary)
                    Text("%")
                        .font(.system(size: 19))
                        .foregroundColor(p.textSecondary)
                }
                Spacer(minLength: 6)
                Text(remainText)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundColor(p.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .lineSpacing(3)
            }
            .padding(.top, 8)

            Capsule()
                .fill(p.track)
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule()
                            .fill(socValid ? p.ok : p.track)
                            .frame(width: g.size.width
                                   * CGFloat(min(max(readout.soc, 0), 100) / 100))
                    }
                }
                .padding(.top, 10)

            // 2×2 读数格
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    cell(label: "总电压", value: totalV > 0.5 ? String(format: "%.1f", totalV) : "--",
                         unit: "V", color: totalV > 0.5 ? p.textPrimary : p.textSecondary)
                    cell(label: "电流",
                         value: hasAmp ? String(format: "%+.1f", snap.current) : "--",
                         unit: "A",
                         color: hasAmp ? (snap.current > 0 ? p.accent : p.ok) : p.textSecondary)
                }
                HStack(spacing: 6) {
                    cell(label: "单体压差",
                         value: hasDelta ? String(format: "%.3f", snap.cellDelta) : "--",
                         unit: "V",
                         color: hasDelta ? (snap.cellDelta > 0.05 ? p.warn : p.textPrimary)
                                         : p.textSecondary)
                    cell(label: "最高温度",
                         value: battT.map { String(format: "%.1f", $0) } ?? "--",
                         unit: "°C",
                         color: battT != nil ? (battT! > 45 ? p.warn : p.textPrimary)
                                             : p.textSecondary)
                }
            }
            .padding(.top, 12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(dash3card)
        .frame(maxHeight: .infinity)
    }

    // MARK: - 右：控制器卡

    private var controllerCard: some View {
        let z = zhike
        return VStack(alignment: .leading, spacing: 0) {
            cardHeader("控制器", chip: settings.controllerVendor == .zhike ? ctrlStateText : "未接入")

            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    cell(label: "母线电压",
                         value: (z?.busVoltageV ?? 0) > 0.5 ? String(format: "%.1f", z!.busVoltageV) : "--",
                         unit: "V", color: (z?.busVoltageV ?? 0) > 0.5 ? p.textPrimary : p.textSecondary)
                    cell(label: "控制器温度",
                         value: ctrlTemp.map { String(format: "%.1f", $0) } ?? "--",
                         unit: "°C", color: tierColor)
                    cell(label: "电机转速",
                         value: hasRpm ? String(format: "%.0f", zhikeRpm) : "--",
                         unit: "rpm", color: hasRpm ? p.accent : p.textSecondary)
                }
                HStack(spacing: 6) {
                    cell(label: "母线电流",
                         value: z != nil ? String(format: "%.0f", z!.busCurrentA) : "--",
                         unit: "A",
                         color: z != nil ? (abs(z!.busCurrentA) > 1 ? p.accent : p.textPrimary)
                                         : p.textSecondary)
                    cell(label: "相线电流",
                         value: z?.phaseCurrentA.map { String(format: "%.1f", $0) } ?? "--",
                         unit: "A", color: z?.phaseCurrentA != nil ? p.textPrimary : p.textSecondary)
                    cell(label: "故障码",
                         value: faultText, unit: "", color: faultColor)
                }
            }
            .padding(.top, 12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(dash3card)
        .frame(maxHeight: .infinity)
    }

    private func cell(label: String, value: String, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(p.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10))
                        .foregroundColor(p.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(p.panelAlt.opacity(0.7)))
    }

    // MARK: - 底栏：MOS / 均衡 / 保护 / BMS

    private var footBar: some View {
        let has = snap.hasData
        let cOn = has && snap.chargeMosOn
        let dOn = has && snap.dischargeMosOn
        let bal = has && (snap.balancingAction != 0 || snap.balancingMask != 0)
        let prot = has && (snap.protectBits != 0 || snap.warnBits != 0)
        let hint = p.textSecondary.opacity(0.6)

        return HStack(spacing: 12) {
            foot("充电 MOS " + (has ? (cOn ? "开启" : "关闭") : "--"),
                 color: has ? (cOn ? p.ok : p.textSecondary) : hint)
            Rectangle().fill(p.stroke).frame(width: 1, height: 12)
            foot("放电 MOS " + (has ? (dOn ? "开启" : "关闭") : "--"),
                 color: has ? (dOn ? p.ok : p.textSecondary) : hint)
            Rectangle().fill(p.stroke).frame(width: 1, height: 12)
            foot("均衡 " + (has ? (bal ? "进行中" : "关闭") : "--"),
                 color: has ? (bal ? p.accent : p.textSecondary) : hint)
            Rectangle().fill(p.stroke).frame(width: 1, height: 12)
            foot("保护 " + (has ? (prot ? "告警" : "正常") : "--"),
                 color: has ? (prot ? p.danger : p.ok) : hint)
            Spacer()
            foot(has ? "BMS 在线" : "BMS 离线", color: has ? p.ok : hint)
        }
        .frame(height: 30)
    }

    private func foot(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    // MARK: - 数据换算

    private var totalV: Double { readout.totalVoltage }
    private var hasAmp: Bool { snap.hasData && abs(snap.current) > 0.05 }
    private var hasDelta: Bool { snap.hasData && snap.cellDelta > 0 }
    private var socValid: Bool { snap.hasData || readout.socEstimated }

    private var remainText: String {
        let full = String(format: "满充 %.1f V", fullV)
        if snap.hasData && snap.remainingAh > 0 {
            return String(format: "剩余 %.1f / %.0f Ah", snap.remainingAh, snap.ratedAh) + "\n" + full
        }
        return "剩余 -- / -- Ah\n" + full
    }

    /// 电池温度：优先探头 1，只有温度数组时取最高探头（与样式 2 同口径）
    private var battT: Double? {
        guard snap.hasData else { return nil }
        if snap.temp1.isFinite, snap.temp1 != 0 { return snap.temp1 }
        if snap.tempCount > 0 {
            let valid = snap.temps.prefix(snap.tempCount).filter { $0.isFinite }
            if let mx = valid.max() { return mx }
        }
        return nil
    }

    private var stateShort: String {
        if totalV <= 0.5 { return "--" }
        return snap.charging ? "充" : (snap.current < -0.05 ? "放" : "静")
    }

    private var stateColor: Color {
        if totalV <= 0.5 { return p.textSecondary }
        if snap.charging { return p.accent }
        if snap.current < -0.05 { return p.ok }
        return p.textSecondary
    }

    private var stateText: String {
        if totalV <= 0.5 { return "--" }
        var s = snap.charging ? "充电中" : (snap.current < -0.05 ? "放电中" : "静置")
        if readout.socEstimated { s += " · 估算" }
        return s
    }

    /// 智科链路有效数据（3 秒新鲜度）；未接智科时为 nil
    private var zhike: ZhikeReadout? {
        guard settings.controllerVendor == .zhike, ctrl.readout.valid else { return nil }
        return ctrl.readout
    }

    private var hasRpm: Bool { (zhike?.rpm ?? 0) > 0.5 }
    private var zhikeRpm: Double { zhike?.rpm ?? 0 }

    /// 控制器温度：智科优先；未接智科时回退 BMS MOS 温度（与样式 2 同口径）
    private var ctrlTemp: Double? {
        if let t = zhike?.tempC { return t }
        if settings.controllerVendor != .zhike, snap.hasData,
           snap.mosTemp.isFinite, snap.mosTemp > 0 {
            return snap.mosTemp
        }
        return nil
    }

    /// ≤50 正常绿 / 50~75 偏热黄 / >75 过热红
    private var tierColor: Color {
        guard let t = ctrlTemp else { return p.textSecondary }
        if t > 75 { return p.danger }
        if t >= 50 { return p.warn }
        return p.ok
    }

    private var faultText: String {
        guard let z = zhike else { return "--" }
        return z.faultBits == 0 ? "正常" : String(format: "0x%04X", z.faultBits)
    }

    private var faultColor: Color {
        guard let z = zhike else { return p.textSecondary }
        return z.faultBits == 0 ? p.ok : p.danger
    }

    /// 卡头胶囊兼任链路状态（与样式 2 的胶囊同口径）
    private var ctrlStateText: String {
        switch ctrl.state {
        case .idle: return "未连接"
        case .scanning: return "搜索中"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .streaming: return "已连接"
        case .reconnecting: return "重连中"
        case .failed: return "未连接"
        }
    }
}

// MARK: - 小圆表

/// 对称小圆表（对应 Android 的 MiniRingView）：环形进度 + 中央读数 + 底部标签。
private struct MiniRing: View {
    var title: String
    var value: String
    var unit: String
    var ratio: Double
    var tint: Color
    var palette: Palette

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 7
            let startDeg = 135.0, sweepDeg = 270.0

            func point(_ deg: Double, radius: CGFloat) -> CGPoint {
                let rad = deg * .pi / 180
                return CGPoint(x: center.x + radius * CGFloat(cos(rad)),
                               y: center.y + radius * CGFloat(sin(rad)))
            }
            func arc(_ radius: CGFloat, _ from: Double, _ to: Double) -> Path {
                var path = Path()
                let steps = max(8, Int(abs(to - from) / 1.5))
                for i in 0...steps {
                    let deg = from + (to - from) * Double(i) / Double(steps)
                    if i == 0 { path.move(to: point(deg, radius: radius)) }
                    else { path.addLine(to: point(deg, radius: radius)) }
                }
                return path
            }

            // 轨道 + 进度弧
            ctx.stroke(arc(r, startDeg, startDeg + sweepDeg),
                       with: .color(palette.track),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round))
            let frac = max(0, min(1, ratio))
            if frac > 0.003, frac.isFinite {
                ctx.stroke(arc(r, startDeg, startDeg + sweepDeg * frac),
                           with: .color(tint),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }
        }
        .overlay {
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 19, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(value == "--" ? palette.textSecondary : palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundColor(palette.textSecondary)
                }
                Text(title)
                    .font(.system(size: 9))
                    .foregroundColor(palette.textSecondary)
            }
        }
    }
}
