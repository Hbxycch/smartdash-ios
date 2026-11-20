import Foundation

/// BmsSnapshot → 接口字段（见 docs/api/telemetry-v1.md）。
///
/// 唯一原则：**拿不到的量不传，绝不传 0 冒充**。
/// 服务端区分不了「真的是 0」和「设备没这个值」，写进库就是脏数据，图上也画不出断点。
enum TelemetryMapping {

    /// 一条电池样本。返回 nil 表示这条不该上报（缺必填项，传上去只会被拒收）。
    /// - Parameter withCells: 是否带逐串电压快照（NCHAR(512)，32 串勉强放下，所以低频发）
    static func sample(from s: BmsSnapshot, ts: Int, withCells: Bool) -> [String: Any]? {
        // 服务端必填三项：总压 / 电流 / SOC。缺任何一个这条就没有业务价值
        guard s.totalVoltage > 1, s.soc > 0.05, s.soc <= 100 else { return nil }

        var m: [String: Any] = [
            "ts": ts,
            "pack_voltage": round(s.totalVoltage, 2),
            "current": round(s.current, 1),      // 充电为正、放电为负，与 App 内部一致
            "soc": round(s.soc, 1),
        ]

        if s.soh > 0 { m["soh"] = Double(s.soh) }
        if s.remainingAh > 0 { m["remain_ah"] = round(s.remainingAh, 1) }
        if s.cycles >= 0 { m["cycles"] = s.cycles }
        // 蚂蚁/蚂蚁新版只给「累计循环容量 Ah」，没有循环次数（cycles 恒为 -1），
        // 服务端用 cycle_ah 单独存，云端实时监控/BMS 分析页才能显示循环容量
        if s.cycleCapacityAh > 0 { m["cycle_ah"] = round(s.cycleCapacityAh, 1) }
        if s.mosTemp.isFinite { m["mos_temp"] = round(s.mosTemp, 1) }

        let cells = s.activeCells
        if let hi = cells.max(), let lo = cells.min(), !cells.isEmpty {
            m["cell_max"] = round(hi, 3)
            m["cell_min"] = round(lo, 3)
            m["cell_avg"] = round(cells.reduce(0, +) / Double(cells.count), 3)
            m["cell_count"] = cells.count
            // cell_diff 服务端会用 max-min 补算，这里不重复传
            if withCells { m["cell_json"] = cells.map { round($0, 3) } }
        } else if s.cellDelta > 0 {
            m["cell_diff"] = round(s.cellDelta, 4)
        }

        // 温度：蚂蚁的 temps[8] 与 temp1/temp2 可能重叠，去重交给服务端聚合，这里只取极值
        let temps = s.temps.filter { $0.isFinite } + [s.temp1, s.temp2].filter { $0.isFinite }
        if let hi = temps.max(), let lo = temps.min() {
            m["temp_max"] = round(hi, 1)
            m["temp_min"] = round(lo, 1)
            m["temp_avg"] = round(temps.reduce(0, +) / Double(temps.count), 1)
        }

        if s.balancingMask != 0 { m["balance_mask"] = Int(s.balancingMask) }
        if s.protectBits != 0 { m["protect_mask"] = Int(truncatingIfNeeded: s.protectBits) }
        if s.warnBits != 0 { m["alarm_mask"] = Int(truncatingIfNeeded: s.warnBits) }

        return m
    }

    /// 一个轨迹点。acc < 0 表示定位无效，直接不报（服务端也会拒）。
    static func point(lat: Double, lng: Double, speed: Double, heading: Double,
                      acc: Double, alt: Double, ts: Int) -> [String: Any]? {
        guard acc >= 0 else { return nil }
        guard abs(lat) > 1e-5 || abs(lng) > 1e-5 else { return nil }   // 0,0 是没定位

        var m: [String: Any] = [
            "ts": ts,
            "lat": round(lat, 7),
            "lng": round(lng, 7),
            "speed": round(max(0, speed), 1),
            "heading": round(heading, 1),
            "acc": round(acc, 1),
        ]
        if alt.isFinite, alt != 0 { m["alt"] = round(alt, 1) }
        return m
    }

    private static func round(_ v: Double, _ digits: Int) -> Double {
        guard v.isFinite else { return 0 }
        let p = pow(10.0, Double(digits))
        return (v * p).rounded() / p
    }
}
