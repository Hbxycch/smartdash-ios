import Foundation

/// 里程统计：GPS 速度按时间积分（与 Android 端 Odometer 同口径）。
///
/// BMS 帧里没有轮速，里程只能从定位来。防漂移三条规则：
///   1. 速度 < 1.5 km/h 不累计（堵车/停车的 GPS 抖动不虚增里程）；
///   2. 两个定位点间隔 > 60 秒丢弃（隧道里断定位很久，中间距离不可信）；
///   3. 速度上限 160 km/h（超出视为漂移）。
/// 每 0.01 km 或 15 秒落盘一次；按本地日期归「今日」。
final class Odometer {

    static let shared = Odometer()

    private let d = UserDefaults.standard
    private var totalKm: Double = 0
    private var todayKm: Double = 0
    private var day = ""                       // "yyyy-MM-dd"，变了就滚动今日
    private var lastTs: Date?                  // 上一个定位点
    private var lastPersistKm: Double = 0
    private var lastPersistAt = Date.distantPast

    private enum Key {
        static let total = "odo_total_km"
        static let today = "odo_today_km"
        static let day = "odo_day"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        totalKm = d.double(forKey: Key.total)
        todayKm = d.double(forKey: Key.today)
        day = d.string(forKey: Key.day) ?? ""
    }

    /// 每个有效定位点喂一次（LocationService.didUpdateLocations）
    func feed(kmh: Double, at ts: Date) {
        if let last = lastTs {
            let dt = ts.timeIntervalSince(last)
            // 间隔异常（倒流或断超过 60s）：这段距离不可信，不积分
            if dt > 0, dt <= 60 {
                let v = min(max(kmh, 0), 160)   // 上限防漂移
                if v >= 1.5 {                    // 低速 GPS 抖动不累计
                    let delta = v * dt / 3600
                    totalKm += delta
                    todayKm += delta
                }
            }
        }
        lastTs = ts

        // 跨天滚动：昨天跑的算进总计，今日清零重新开始
        let today = Self.dayFormatter.string(from: ts)
        if today != day {
            day = today
            todayKm = 0
            persist()
            return
        }

        // 每 0.01 km 或 15 秒落盘一次，避免频繁写盘
        if totalKm - lastPersistKm >= 0.01, Date().timeIntervalSince(lastPersistAt) >= 15 {
            persist()
        }
    }

    private func persist() {
        lastPersistKm = totalKm
        lastPersistAt = Date()
        d.set(totalKm, forKey: Key.total)
        d.set(todayKm, forKey: Key.today)
        d.set(day, forKey: Key.day)
    }

    // MARK: - 展示

    var todayText: String { String(format: "%.1f", todayKm) }
    var totalText: String { String(format: "%.1f", totalKm) }

    /// 「今日 12.3 · 总计 456.7 km」一口式文案（样式 2 底部状态行用）
    var summaryText: String {
        String(format: "今日 %.1f · 总计 %.1f km", todayKm, totalKm)
    }
}
