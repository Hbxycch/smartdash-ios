import Foundation

/// 电池化学体系 × 串数配置。
///
/// 作用与 Android 版一致：
///  ① 串数 → 整包额定/满充/欠压三个基准电压；
///  ② 单体均值 × 串数 → 总电压兜底（保护板只报单体时）；
///  ③ 总压 ÷ 串数 → 单体电压 → 查开路电压曲线估算 SOC（仅在板子不报 SOC 时）。
///
/// 单体基准（V）：铁锂 3.20/3.65/2.50，三元 3.70/4.20/3.00，铅酸 2.00/2.45/1.75。
/// 铅酸按 2V 单体计，12V 电池 = 6 串。
enum Chemistry: String, CaseIterable, Identifiable {
    case lfp
    case ncm
    case lead

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lfp: return "磷酸铁锂"
        case .ncm: return "三元锂"
        case .lead: return "铅酸"
        }
    }

    var shortLabel: String {
        switch self {
        case .lfp: return "铁锂"
        case .ncm: return "三元"
        case .lead: return "铅酸"
        }
    }

    var cellNominal: Double {
        switch self {
        case .lfp: return 3.20
        case .ncm: return 3.70
        case .lead: return 2.00
        }
    }

    var cellFull: Double {
        switch self {
        case .lfp: return 3.65
        case .ncm: return 4.20
        case .lead: return 2.45
        }
    }

    var cellCutoff: Double {
        switch self {
        case .lfp: return 2.50
        case .ncm: return 3.00
        case .lead: return 1.75
        }
    }

    /// 常见串数（切换体系时的默认值）
    var defaultSeries: Int {
        switch self {
        case .lfp: return 16     // 48V 铁锂
        case .ncm: return 14     // 48V 三元
        case .lead: return 6     // 12V 铅酸
        }
    }

    /// {单体电压, SOC%}，电压从高到低
    var socCurve: [(v: Double, soc: Double)] {
        switch self {
        case .lfp:
            return [(3.40, 100), (3.33, 90), (3.31, 80), (3.29, 60), (3.27, 40),
                    (3.25, 30), (3.20, 20), (3.12, 10), (3.00, 5), (2.60, 0)]
        case .ncm:
            return [(4.15, 100), (4.06, 90), (3.98, 80), (3.88, 65), (3.78, 50),
                    (3.70, 35), (3.58, 20), (3.45, 10), (3.30, 5), (3.00, 0)]
        case .lead:
            return [(2.13, 100), (2.10, 90), (2.07, 80), (2.04, 70), (2.00, 55),
                    (1.97, 40), (1.94, 30), (1.90, 20), (1.85, 10), (1.75, 0)]
        }
    }
}

enum BatteryProfile {
    static let maxSeries = 32

    static func clampSeries(_ n: Int) -> Int { max(1, min(maxSeries, n)) }

    static func packNominalV(_ c: Chemistry, _ series: Int) -> Double { c.cellNominal * Double(clampSeries(series)) }
    static func packFullV(_ c: Chemistry, _ series: Int) -> Double { c.cellFull * Double(clampSeries(series)) }
    static func packCutoffV(_ c: Chemistry, _ series: Int) -> Double { c.cellCutoff * Double(clampSeries(series)) }

    /// 有效单体均值 × 串数；无有效单体返回 0
    static func packVFromCells(series: Int, cells: [Double]) -> Double {
        let valid = cells.filter { $0 > 0.5 }
        guard !valid.isEmpty else { return 0 }
        let avg = valid.reduce(0, +) / Double(valid.count)
        return avg * Double(clampSeries(series))
    }

    /// 单体电压 → 电量百分比（区间外收敛到 0/100）
    static func socFromCellV(_ c: Chemistry, _ cellV: Double) -> Double {
        let curve = c.socCurve
        guard let first = curve.first, let last = curve.last else { return 0 }
        if cellV >= first.v { return 100 }
        if cellV <= last.v { return 0 }
        for i in 0..<(curve.count - 1) {
            let hi = curve[i], lo = curve[i + 1]
            if cellV <= hi.v && cellV >= lo.v {
                let t = (cellV - lo.v) / max(0.0001, hi.v - lo.v)
                return lo.soc + t * (hi.soc - lo.soc)
            }
        }
        return 0
    }

    /// 总压 → 电量；参数不足返回 -1（表示无法估算）
    static func socFromPackV(_ c: Chemistry, series: Int, packV: Double) -> Double {
        guard packV > 0 else { return -1 }
        return socFromCellV(c, packV / Double(clampSeries(series)))
    }

    static func cellAvgV(series: Int, packV: Double) -> Double {
        packV <= 0 ? 0 : packV / Double(clampSeries(series))
    }

    /// "16 串 · 单体 3.20 / 3.65 / 2.50 V"
    static func cellHint(_ c: Chemistry, _ series: Int) -> String {
        String(format: "%d 串 · 单体 %.2f / %.2f / %.2f V",
               clampSeries(series), c.cellNominal, c.cellFull, c.cellCutoff)
    }

    /// "额定 51.2 V · 满充 58.4 V · 欠压 40.0 V"
    static func packHint(_ c: Chemistry, _ series: Int) -> String {
        String(format: "额定 %.1f V · 满充 %.1f V · 欠压 %.1f V",
               packNominalV(c, series), packFullV(c, series), packCutoffV(c, series))
    }
}
