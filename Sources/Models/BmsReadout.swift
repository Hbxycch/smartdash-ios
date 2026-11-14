import Foundation

/// 把原始快照 + 用户配置换算成界面要显示的数值。
/// 换算规则与 Android 版一致：
///   ① 板子报了总压就用实测；只报单体时用 单体均值 × 串数 兜底；
///   ② 板子报了 SOC 就用实测；没有时用 总压 ÷ 串数 → 查曲线估算，并标记「估算」。
struct BmsReadout {
    let soc: Double
    let socEstimated: Bool
    let totalVoltage: Double
    let voltageEstimated: Bool
    let cellAvg: Double
    let packHint: String
    let cellHint: String

    init(snapshot s: BmsSnapshot, settings: AppSettings) {
        let chemistry = settings.chemistry
        let series = settings.series

        let cellsPack = BatteryProfile.packVFromCells(series: series, cells: s.activeCells)
        if s.totalVoltage > 0.5 {
            totalVoltage = s.totalVoltage
            voltageEstimated = false
        } else if cellsPack > 0 {
            totalVoltage = cellsPack
            voltageEstimated = true
        } else {
            totalVoltage = 0
            voltageEstimated = false
        }

        if s.soc > 0 || s.hasData {
            soc = s.soc
            socEstimated = false
        } else {
            let est = BatteryProfile.socFromPackV(chemistry, series: series, packV: totalVoltage)
            soc = est < 0 ? 0 : est
            socEstimated = est >= 0
        }

        cellAvg = BatteryProfile.cellAvgV(series: series, packV: totalVoltage)
        packHint = BatteryProfile.packHint(chemistry, series)
        cellHint = BatteryProfile.cellHint(chemistry, series)
    }

    /// 电量分档色（用于进度条与数字）
    var socLevel: SocLevel {
        if soc >= 50 { return .good }
        if soc >= 20 { return .ok }
        if soc >= 10 { return .low }
        return .critical
    }

    enum SocLevel { case good, ok, low, critical }
}
