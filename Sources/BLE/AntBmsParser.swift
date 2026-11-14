import Foundation

/// 蚂蚁保护板（ANT-BMS）BLE 协议，与 Android 版逐字段一致。
///
/// 请求-应答式，帧结构（小端）：
///   7E A1 | FUNC | ADDR(2B) | LEN | PAYLOAD(LEN) | CRC(2B) | AA 55
///   CRC-16/MODBUS（初值 0xFFFF，多项式 0xA001），范围 = FUNC 起到 PAYLOAD 末字节，低字节在前。
///
/// 状态帧偏移（先由电芯数/温度数算出动态基址 o2）：
///   7 电池状态  8 温度探头数  9 电芯数  10-17 保护位
///   34 起 电芯 u16(mV)  34+o2 MOS 温度  36+o2 均衡器温度
///   38+o2 总压 u16 0.01V  40+o2 电流 i16 0.1A  42+o2 SOC  44+o2 SOH
///   46+o2 充电 MOS  47+o2 放电 MOS  48+o2 均衡器状态
///   50+o2 额定容量 µAh  54+o2 剩余容量  58+o2 循环容量 0.001Ah
///   62+o2 功率 i32 W  66+o2 运行秒数  70+o2 均衡电芯掩码
///   74+o2 最高单体  76+o2 最高号  78+o2 最低单体  80+o2 最低号
///   o2 = 电芯数*2 + 温度探头数*2
final class AntBmsParser {

    static let fnStatus: UInt8 = 0x11
    static let fnDevice: UInt8 = 0x12

    private var buf: [UInt8] = []
    private var snapshot = BmsSnapshot()

    func readyCommands() -> [[UInt8]] {
        [Self.buildDeviceRequest(), Self.buildStatusRequest()]
    }

    func pollCommand() -> [UInt8]? { Self.buildStatusRequest() }
    var pollPeriod: TimeInterval { 1.0 }

    // ── 命令帧 ──

    static func buildStatusRequest() -> [UInt8] { buildFrame(0x01, 0x0000, 0xBE) }
    static func buildDeviceRequest() -> [UInt8] { buildFrame(0x02, 0x026C, 0x20) }

    private static func buildFrame(_ fn: UInt8, _ address: UInt16, _ value: UInt8) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 10)
        f[0] = 0x7E; f[1] = 0xA1; f[2] = fn
        f[3] = UInt8(address & 0xFF)
        f[4] = UInt8((address >> 8) & 0xFF)
        f[5] = value
        let crc = crc16(f, 1, 5)
        f[6] = UInt8(crc & 0xFF)
        f[7] = UInt8((crc >> 8) & 0xFF)
        f[8] = 0xAA; f[9] = 0x55
        return f
    }

    /// CRC-16/MODBUS
    static func crc16(_ b: [UInt8], _ off: Int, _ len: Int) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for i in off..<(off + len) {
            crc ^= UInt16(b[i])
            for _ in 0..<8 {
                if (crc & 0x0001) != 0 {
                    crc >>= 1
                    crc ^= 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    // ── 收数据 ──

    func feed(_ bytes: [UInt8]) -> BmsSnapshot? {
        guard !bytes.isEmpty else { return nil }
        buf.append(contentsOf: bytes)
        let updated = parse()
        if buf.count > 4096 { buf.removeAll() }
        return updated ? snapshot : nil
    }

    private func parse() -> Bool {
        var updated = false
        while buf.count >= 6 {
            // 1) 对齐帧头 7E A1
            guard let start = findFirst([0x7E, 0xA1]) else {
                buf.removeAll()
                return updated
            }
            if start > 0 { buf.removeFirst(start) }
            guard buf.count >= 6 else { return updated }

            let fn = buf[2]
            var total: Int

            if fn == Self.fnDevice {
                // 设备信息帧的长度字段与实际帧长不一致，只能用帧尾定位
                guard let end = findLast([0xAA, 0x55]) else { return updated }
                total = end + 2
            } else {
                let dataLen = Int(buf[5])
                total = 6 + dataLen + 4
                if total < 10 || total > 300 {
                    buf.removeFirst(1)
                    continue
                }
                if buf.count < total { return updated }
                if buf[total - 2] != 0xAA || buf[total - 1] != 0x55 {
                    buf.removeFirst(1)
                    continue
                }
                let calc = Self.crc16(buf, 1, total - 5)
                let remote = UInt16(buf[total - 3]) | (UInt16(buf[total - 4]) << 8)
                if calc != remote {
                    buf.removeFirst(1)
                    continue
                }
            }

            guard buf.count >= total else { return updated }
            let frame = Array(buf[0..<total])
            buf.removeFirst(total)

            if fn == Self.fnStatus {
                if parseStatus(frame) { updated = true }
            } else if fn == Self.fnDevice {
                parseDevice(frame)
            }
        }
        return updated
    }

    private func findFirst(_ pattern: [UInt8]) -> Int? {
        guard buf.count >= pattern.count else { return nil }
        for i in 0...(buf.count - pattern.count) where buf[i] == pattern[0] && buf[i + 1] == pattern[1] {
            return i
        }
        return nil
    }

    private func findLast(_ pattern: [UInt8]) -> Int? {
        guard buf.count >= pattern.count else { return nil }
        var i = buf.count - pattern.count
        while i >= 2 {
            if buf[i] == pattern[0] && buf[i + 1] == pattern[1] { return i }
            i -= 1
        }
        return nil
    }

    // ── 状态帧 ──

    private func parseStatus(_ f: [UInt8]) -> Bool {
        guard f.count >= 90 else { return false }
        let cells = Int(f[9])
        guard cells > 0 && cells <= 32 else { return false }
        let tCount = min(Int(f[8]), 6)

        let off = cells * 2
        let o2 = off + tCount * 2
        guard f.count >= 86 + o2 else { return false }

        snapshot.cellCount = cells
        for i in 0..<cells { snapshot.cells[i] = Double(u16(f, 34 + i * 2)) * 0.001 }
        if cells < snapshot.cells.count {
            for i in cells..<snapshot.cells.count { snapshot.cells[i] = 0 }
        }

        snapshot.tempCount = tCount
        for i in 0..<tCount { snapshot.temps[i] = Double(s16(f, 34 + off + i * 2)) }
        if tCount < snapshot.temps.count {
            for i in tCount..<snapshot.temps.count { snapshot.temps[i] = .nan }
        }

        snapshot.mosTemp = Double(s16(f, 34 + o2))
        snapshot.balancerTemp = Double(s16(f, 36 + o2))

        snapshot.totalVoltage = Double(u16(f, 38 + o2)) * 0.01
        snapshot.current = Double(s16(f, 40 + o2)) * 0.1
        let soc = u16(f, 42 + o2)
        if soc >= 0 && soc <= 100 { snapshot.soc = Double(soc) }
        snapshot.soh = u16(f, 44 + o2)
        snapshot.charging = snapshot.current > 0.05

        let chargeMos = Int(f[46 + o2])
        let dischargeMos = Int(f[47 + o2])
        let balancer = Int(f[48 + o2])
        snapshot.chargeMosOn = chargeMos == 0x01
        snapshot.dischargeMosOn = dischargeMos == 0x01
        snapshot.balancerOn = balancer == 0x04
        snapshot.chargeMosText = Self.chargeMosText(chargeMos)
        snapshot.dischargeMosText = Self.dischargeMosText(dischargeMos)
        snapshot.balancerText = Self.balancerText(balancer)
        snapshot.balancingAction = snapshot.balancerOn ? 1 : 0

        let rated = Double(u32(f, 50 + o2)) * 0.000001
        if rated > 0.1 && rated < 5000 { snapshot.ratedAh = rated }
        snapshot.remainingAh = Double(u32(f, 54 + o2)) * 0.000001
        snapshot.cycleCapacityAh = Double(u32(f, 58 + o2)) * 0.001
        snapshot.powerWatt = Double(s32(f, 62 + o2))
        snapshot.runtimeS = UInt64(u32(f, 66 + o2))
        snapshot.balanceCellMask = UInt32(bitPattern: s32(f, 70 + o2))

        snapshot.maxCellV = Double(u16(f, 74 + o2)) * 0.001
        snapshot.maxCellIdx = u16(f, 76 + o2)
        snapshot.minCellV = Double(u16(f, 78 + o2)) * 0.001
        snapshot.minCellIdx = u16(f, 80 + o2)
        snapshot.avgCellV = snapshot.cellCount > 0
            ? snapshot.activeCells.reduce(0, +) / Double(max(1, snapshot.activeCells.count)) : 0

        snapshot.statusText = Self.statusText(Int(f[7]))
        snapshot.protectBits = u64(f, 10)
        snapshot.warnBits = u64(f, 18)
        snapshot.lastUpdate = Date()
        return true
    }

    private func parseDevice(_ f: [UInt8]) {
        guard f.count >= 38 else { return }
        snapshot.deviceModel = ascii(f, 6, 16)
        snapshot.firmware = ascii(f, 22, 16)
    }

    private func ascii(_ f: [UInt8], _ off: Int, _ len: Int) -> String {
        var end = off
        while end < off + len && end < f.count && f[end] != 0 { end += 1 }
        return String(decoding: f[off..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ── 小端读取 ──

    private func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | (Int(b[i + 1]) << 8) }
    private func s16(_ b: [UInt8], _ i: Int) -> Int { let v = u16(b, i); return v >= 0x8000 ? v - 0x10000 : v }
    private func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
    private func s32(_ b: [UInt8], _ i: Int) -> Int32 { Int32(bitPattern: u32(b, i)) }
    private func u64(_ b: [UInt8], _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
        return v
    }

    // ── 状态码 → 中文 ──

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 0x01: return "静置"
        case 0x02: return "充电中"
        case 0x03: return "放电中"
        case 0x04: return "待机"
        case 0x05: return "故障"
        default: return "未知"
        }
    }

    private static func chargeMosText(_ code: Int) -> String {
        let t = ["关闭", "开启", "过充保护", "过流保护", "电池已满", "总压过高", "电池过温",
                 "MOS 过温", "电流异常", "均衡线断线", "主板过温", "保留", "开启失败",
                 "放电 MOS 异常", "等待", "手动关闭", "二级过压", "低温保护", "压差过大",
                 "保留", "自检错误"]
        return code >= 0 && code < t.count ? t[code] : "未知"
    }

    private static func dischargeMosText(_ code: Int) -> String {
        let t = ["关闭", "开启", "过放保护", "过流保护", "二级过流", "总压欠压", "电池过温",
                 "MOS 过温", "电流异常", "均衡线断线", "主板过温", "充电 MOS 开启", "短路保护",
                 "放电 MOS 异常", "开启失败", "手动关闭", "二级低压", "低温保护", "压差过大",
                 "自检错误"]
        return code >= 0 && code < t.count ? t[code] : "未知"
    }

    private static func balancerText(_ code: Int) -> String {
        switch code {
        case 0x00: return "关闭"
        case 0x01: return "超限均衡"
        case 0x02: return "充电压差均衡"
        case 0x03: return "均衡过温"
        case 0x04: return "自动均衡"
        case 0x0A: return "主板过温"
        default: return "未知"
        }
    }
}
