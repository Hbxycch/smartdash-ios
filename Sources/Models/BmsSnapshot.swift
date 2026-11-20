import Foundation

/// BMS 实时数据快照（值类型）。极空与蚂蚁共用，各自只填自己有的字段。
/// 解析器每秒产出若干次，SwiftUI 直接按值渲染，避免共享引用带来的时序问题。
struct BmsSnapshot {
    var soc: Double = 0                 // 0~100
    var totalVoltage: Double = 0        // V
    var current: Double = 0             // A，正=充电 负=放电
    var remainingAh: Double = 0
    var ratedAh: Double = 0               // 0 = 未知（未连接时不显示假数据）
    var soh: Int = 0
    var cycles: Int = -1                // -1 = 协议未提供
    var cells: [Double] = Array(repeating: 0, count: 32)
    var mosTemp: Double = .nan
    var temp1: Double = .nan
    var temp2: Double = .nan
    var balancingMask: UInt32 = 0
    var balancingAction: Int = 0        // 0=未均衡 1=充电均衡 2=放电均衡
    var charging: Bool = false
    var fullChargeV: Double = 0         // 0 = 未知
    var firmware: String = ""
    var cellCount: Int = 0
    var passwordOk: Bool?               // nil=未校验 true=通过 false=密码错误
    var lastUpdate: Date?

    // ── 蚂蚁（ANT-BMS）专有 ──
    var tempCount: Int = 0
    var temps: [Double] = Array(repeating: .nan, count: 8)
    var balancerTemp: Double = .nan
    var statusText: String = "--"
    var chargeMosText: String = "--"
    var dischargeMosText: String = "--"
    var balancerText: String = "--"
    var chargeMosOn = false
    var dischargeMosOn = false
    var balancerOn = false
    var maxCellV: Double = 0
    var maxCellIdx: Int = 0
    var minCellV: Double = 0
    var minCellIdx: Int = 0
    var avgCellV: Double = 0
    var powerWatt: Double = 0
    var protectBits: UInt64 = 0
    var warnBits: UInt64 = 0
    var cycleCapacityAh: Double = 0
    var runtimeS: UInt64 = 0
    var deviceModel: String = ""
    var balanceCellMask: UInt32 = 0

    /// 有效电芯（按 cellCount 截断并剔除空槽）
    var activeCells: [Double] {
        let n = cellCount > 0 ? min(cellCount, cells.count) : cells.count
        guard n > 0 else { return [] }
        return cells[0..<n].filter { $0 > 0 }
    }

    /// 有效压差：只统计实际存在的电芯
    var cellDelta: Double {
        let v = activeCells
        guard let mn = v.min(), let mx = v.max() else { return 0 }
        return mx - mn
    }

    var powerW: Double { totalVoltage * abs(current) }

    /// 充放状态：蚂蚁等协议直出 BMS 自判 statusText（充电中/放电中/静置/待机/故障），优先用；
    /// JK 等无此字段的协议按解析层 charging 标志 + 电流幅值兜底（charging 的符号约定
    /// 已在各解析层处理：JK 正=充电、蚂蚁充电为负，这里不重复判符号）。
    var flowText: String {
        if !statusText.isEmpty && statusText != "--" { return statusText }
        if charging { return "充电中" }
        if abs(current) > 0.05 { return "放电中" }
        return "静置"
    }

    var hasData: Bool { lastUpdate != nil }
}
