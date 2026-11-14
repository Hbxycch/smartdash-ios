import Foundation
import SwiftUI

/// 电池信息页：概览 + 电芯网格 + 厂家专有信息 + 设备信息。
/// 极空与蚂蚁共用这一页，靠 settings.vendor 决定附加区块。
struct BatteryPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var service: BmsService

    var body: some View {
        let snap = service.snapshot
        let readout = BmsReadout(snapshot: snap, settings: settings)

        ScrollView {
            VStack(spacing: 12) {
                if !snap.hasData {
                    emptyHint
                }
                summaryCard(snap, readout)
                cellsCard(snap)
                if settings.vendor == .ant { antCard(snap) }
                deviceCard(snap)
            }
            .padding(12)
        }
    }

    private var emptyHint: some View {
        let p = settings.palette
        return HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundColor(p.textSecondary)
            Text("尚未收到数据：点右上角连接保护板，或用演示模式先看界面")
                .font(.system(size: 12))
                .foregroundColor(p.textSecondary)
            Spacer()
        }
        .card(padding: 12)
    }

    private func summaryCard(_ s: BmsSnapshot, _ r: BmsReadout) -> some View {
        let p = settings.palette
        let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(settings.vendor.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(p.textSecondary)
                Spacer()
                Text(s.statusText == "--" ? (s.hasData ? s.flowText : "--") : s.statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(s.charging ? p.ok : p.accent)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                metric("电量", String(format: "%.0f%%", r.soc), p.socColor(r.socLevel))
                metric("总电压", String(format: "%.2f V", r.totalVoltage), p.textPrimary)
                metric("电流", String(format: "%+.1f A", s.current), s.current >= 0 ? p.ok : p.accent)
                metric("功率", String(format: "%.0f W", s.powerW), p.textPrimary)
                metric("压差", String(format: "%.0f mV", s.cellDelta * 1000),
                       s.cellDelta > 0.05 ? p.warn : p.textPrimary)
                metric("剩余", s.ratedAh > 0 ? String(format: "%.1f / %.0f Ah", s.remainingAh, s.ratedAh) : "--", p.textPrimary)
                metric("MOS 温度", tempText(s.mosTemp), p.textPrimary)
                metric("SOH", s.soh > 0 ? "\(s.soh)%" : "--", p.textPrimary)
            }
        }
        .card()
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        let p = settings.palette
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(p.textSecondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 电芯

    private func cellsCard(_ s: BmsSnapshot) -> some View {
        let p = settings.palette
        let count = max(s.cellCount, 0)
        let avg = s.activeCells.isEmpty ? 0 : s.activeCells.reduce(0, +) / Double(s.activeCells.count)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("电芯电压")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(p.textSecondary)
                Spacer()
                if count > 0 {
                    Text("\(count) 串")
                        .font(.system(size: 11))
                        .foregroundColor(p.textSecondary)
                }
            }

            if count == 0 {
                Text("无电芯数据")
                    .font(.system(size: 12))
                    .foregroundColor(p.textSecondary)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 8)], spacing: 8) {
                    ForEach(0..<count, id: \.self) { i in
                        let v = s.cells[i]
                        let dev = avg > 0 ? v - avg : 0
                        let tint: Color = abs(dev) > 0.06 ? p.danger : (abs(dev) > 0.03 ? p.warn : p.textPrimary)
                        let balancing = (settings.vendor == .ant
                                         ? (s.balanceCellMask >> UInt32(i)) & 1 == 1
                                         : (s.balancingMask >> UInt32(i)) & 1 == 1)

                        VStack(spacing: 2) {
                            HStack(spacing: 3) {
                                Text("C\(i + 1)")
                                    .font(.system(size: 9))
                                    .foregroundColor(p.textSecondary)
                                if balancing {
                                    Circle().fill(p.ok).frame(width: 5, height: 5)
                                }
                            }
                            Text(v > 0 ? String(format: "%.3f", v) : "--")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(tint)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(abs(dev) > 0.03 ? tint.opacity(0.12) : p.panelAlt)
                        )
                    }
                }
                Text(String(format: "最高 %.3f / 最低 %.3f V · 均衡动作 %@",
                            s.maxCellV > 0 ? s.maxCellV : (s.activeCells.max() ?? 0),
                            s.minCellV > 0 ? s.minCellV : (s.activeCells.min() ?? 0),
                            balancingText(s.balancingAction)))
                    .font(.system(size: 10))
                    .foregroundColor(p.textSecondary)
            }
        }
        .card()
    }

    private func balancingText(_ action: Int) -> String {
        switch action {
        case 1: return "充电均衡"
        case 2: return "放电均衡"
        default: return "未均衡"
        }
    }

    // MARK: - 蚂蚁专有

    private func antCard(_ s: BmsSnapshot) -> some View {
        let p = settings.palette
        return VStack(alignment: .leading, spacing: 10) {
            Text("MOS / 均衡器")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(p.textSecondary)

            row("电池状态", s.statusText, s.statusText == "故障" ? p.danger : p.textPrimary)
            row("充电 MOS", s.chargeMosText, s.chargeMosOn ? p.ok : p.danger)
            row("放电 MOS", s.dischargeMosText, s.dischargeMosOn ? p.ok : p.danger)
            row("均衡器", s.balancerText, s.balancerOn ? p.ok : p.textSecondary)
            row("最高单体", String(format: "%.3f V (C%d)", s.maxCellV, s.maxCellIdx + 1), p.textPrimary)
            row("最低单体", String(format: "%.3f V (C%d)", s.minCellV, s.minCellIdx + 1), p.textPrimary)
            row("保护 / 告警位", String(format: "0x%llX / 0x%llX", s.protectBits, s.warnBits),
                (s.protectBits != 0 || s.warnBits != 0) ? p.warn : p.textSecondary)
            row("循环容量", String(format: "%.1f Ah", s.cycleCapacityAh), p.textPrimary)
            row("运行时长", runtimeText(s.runtimeS), p.textPrimary)
            if s.tempCount > 0 {
                row("探头温度", (0..<s.tempCount).map { tempText(s.temps[$0]) }.joined(separator: " / "), p.textPrimary)
            }
        }
        .card()
    }

    private func runtimeText(_ seconds: UInt64) -> String {
        guard seconds > 0 else { return "--" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }

    // MARK: - 设备信息

    private func deviceCard(_ s: BmsSnapshot) -> some View {
        let p = settings.palette
        return VStack(alignment: .leading, spacing: 10) {
            Text("设备信息")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(p.textSecondary)
            if !s.deviceModel.isEmpty { row("型号", s.deviceModel, p.textPrimary) }
            row("固件", s.firmware.isEmpty ? "--" : s.firmware, p.textPrimary)
            row("循环次数", s.cycles >= 0 ? "\(s.cycles)" : "--", p.textPrimary)
            row("额定容量", s.ratedAh > 0 ? String(format: "%.0f Ah", s.ratedAh) : "--", p.textPrimary)
            row("链路状态", service.state.text, p.textSecondary)
            row("信号强度", service.lastRSSI == 0 ? "--" : "\(service.lastRSSI) dBm", p.textSecondary)
            row("最后更新", updateText(s.lastUpdate), p.textSecondary)
            if let ok = s.passwordOk, ok == false {
                row("密码校验", "与设备不一致", p.danger)
            }
        }
        .card()
    }

    private func row(_ title: String, _ value: String, _ color: Color) -> some View {
        let p = settings.palette
        return HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(p.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func tempText(_ v: Double) -> String {
        v.isNaN ? "--" : String(format: "%.1f℃", v)
    }

    private func updateText(_ d: Date?) -> String {
        guard let d else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
