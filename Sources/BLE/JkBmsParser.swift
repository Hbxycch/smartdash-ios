import Foundation

/// JK-BMS 新一代 BLE 协议解析（JK02 系列），与 Android 版逐字段一致。
///
/// 命令帧（20 字节固定）：AA 55 90 EB | CMD | LEN | VALUE(4B) | 填充(9B) | SUM
///   0x97 请求设备信息，0x96 请求电芯数据，SUM = 字节 0..18 累加 & 0xFF
/// 应答帧：55 AA EB 90 | TYPE | ... | SUM，共 300 字节（少数固件 320 字节，前 300 一致）
///   TYPE 0x01 设置帧 / 0x02 电芯帧 / 0x03 设备信息帧，SUM = 除末字节外累加
///
/// 电芯帧关键偏移（绝对位置）：
///   6-69 电芯 mV u16LE（槽位 1-32）  112 MOS 温度 i16 0.1℃
///   118 总压 u32 0.001V  126 电流 i32 0.001A（正=充电）
///   130/132 探头 1/2  140 均衡动作  141 SOC  142 剩余容量  146 额定容量
///   150 循环次数  158 SOH
/// 固件主版本 ≥ 11 时，112 之后的字段整体 +32 字节。
final class JkBmsParser {

    static let header: [UInt8] = [0x55, 0xAA, 0xEB, 0x90]
    static let cmdCell: UInt8 = 0x96
    static let cmdDevice: UInt8 = 0x97
    private static let frameLen = 300

    private var buf: [UInt8] = []
    private var cellShift = 0
    private var snapshot = BmsSnapshot()
    var expectedPassword = ""

    /// 订阅成功后要发的命令：先设备信息（拿固件版本），再电芯数据
    func readyCommands() -> [[UInt8]] {
        [Self.buildCommand(Self.cmdDevice), Self.buildCommand(Self.cmdCell)]
    }

    /// 极空是推送式，握手后板子持续推数据，不需要轮询
    func pollCommand() -> [UInt8]? { nil }
    var pollPeriod: TimeInterval { 0 }

    static func buildCommand(_ cmd: UInt8) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 20)
        f[0] = 0xAA; f[1] = 0x55; f[2] = 0x90; f[3] = 0xEB
        f[4] = cmd
        var sum = 0
        for i in 0..<19 { sum += Int(f[i]) }
        f[19] = UInt8(sum & 0xFF)
        return f
    }

    func feed(_ bytes: [UInt8]) -> BmsSnapshot? {
        guard !bytes.isEmpty else { return nil }
        buf.append(contentsOf: bytes)
        var updated = false
        var consumed = 0

        while buf.count - consumed >= 4 {
            guard let start = findHeader(from: consumed) else {
                consumed = max(consumed, buf.count - 3)      // 保留末尾可能是半个帧头
                break
            }
            if start > consumed { consumed = start }
            let avail = buf.count - consumed
            if avail < Self.frameLen { break }
            if crcOK(off: consumed, len: Self.frameLen) {
                handle(off: consumed)
                updated = true
                consumed += Self.frameLen
                continue
            }
            if avail < 320 { break }
            if crcOK(off: consumed, len: 320) {
                handle(off: consumed)
                updated = true
                consumed += 320
                continue
            }
            consumed += 1                                    // CRC 都不对 → 丢一个字节重新同步
        }

        if consumed > 0 { buf.removeFirst(min(consumed, buf.count)) }
        if buf.count > 8192 { buf.removeAll() }
        return updated ? snapshot : nil
    }

    // ── 帧同步 ──

    private func findHeader(from: Int) -> Int? {
        guard buf.count >= Self.header.count else { return nil }
        var i = from
        while i <= buf.count - Self.header.count {
            if buf[i] == Self.header[0], buf[i + 1] == Self.header[1],
               buf[i + 2] == Self.header[2], buf[i + 3] == Self.header[3] {
                return i
            }
            i += 1
        }
        return nil
    }

    private func crcOK(off: Int, len: Int) -> Bool {
        guard off + len <= buf.count else { return false }
        var sum = 0
        for i in off..<(off + len - 1) { sum += Int(buf[i]) }
        return UInt8(sum & 0xFF) == buf[off + len - 1]
    }

    private func handle(off: Int) {
        switch buf[off + 4] {
        case 0x02: parseCells(off)
        case 0x03: parseDevice(off)
        case 0x01: parseSettings(off)
        default: return
        }
        snapshot.lastUpdate = Date()
    }

    private func parseCells(_ off: Int) {
        let s = cellShift
        var count = 0
        for i in 0..<32 {
            let mv = u16(off + 6 + i * 2)
            if mv > 300 && mv < 0xF000 {
                count += 1
                snapshot.cells[i] = Double(mv) / 1000
            } else if i >= count {
                snapshot.cells[i] = 0
            }
        }
        if count > 0 { snapshot.cellCount = max(snapshot.cellCount, count) }

        snapshot.mosTemp = sane(Double(s16(off + 112 + s)) / 10)
        snapshot.totalVoltage = Double(u32(off + 118 + s)) / 1000
        snapshot.current = Double(s32(off + 126 + s)) / 1000
        snapshot.charging = snapshot.current > 0.05
        snapshot.temp1 = sane(Double(s16(off + 130 + s)) / 10)
        snapshot.temp2 = sane(Double(s16(off + 132 + s)) / 10)
        snapshot.balancingMask = UInt32(buf[off + 140 + s])
        let soc = Int(buf[off + 141 + s])
        if soc >= 0 && soc <= 100 { snapshot.soc = Double(soc) }
        snapshot.remainingAh = Double(u32(off + 142 + s)) / 1000
        let rated = Double(u32(off + 146 + s)) / 1000
        if rated > 0 && rated < 5000 { snapshot.ratedAh = rated }
        let cycles = Int(u32(off + 150 + s))
        if cycles >= 0 && cycles < 100000 { snapshot.cycles = cycles }
        let soh = Int(buf[off + 158 + s])
        snapshot.soh = soh > 100 ? 0 : soh
    }

    /// 温度探头未接时是极端值 → NaN，UI 显示 "--"
    private func sane(_ v: Double) -> Double { (v < -40 || v > 120) ? .nan : v }

    private func parseDevice(_ off: Int) {
        snapshot.firmware = cstr(off + 30, 8)
        if let dot = snapshot.firmware.firstIndex(of: "."),
           let major = Int(snapshot.firmware[..<dot].trimmingCharacters(in: .whitespaces)) {
            cellShift = major >= 11 ? 32 : 0
        }
        if !expectedPassword.isEmpty {
            let p1 = cstr(off + 62, 16)
            let p2 = cstr(off + 97, 5)
            snapshot.passwordOk = (expectedPassword == p1 || expectedPassword == p2)
        }
    }

    private func parseSettings(_ off: Int) {
        let rcv = u32(off + 38)                                  // 单体请求充电电压 mV
        if rcv > 1000 && rcv < 10000 {
            var cc = Int(buf[off + 114])
            if cc <= 0 || cc > 32 { cc = snapshot.cellCount }
            if cc > 0 && cc <= 32 { snapshot.fullChargeV = Double(rcv) / 1000 * Double(cc) }
        }
        let rated = Double(u32(off + 130)) / 1000
        if rated > 0 && rated < 5000 { snapshot.ratedAh = rated }
    }

    // ── 小端读取 ──

    private func u16(_ p: Int) -> Int { Int(buf[p]) | (Int(buf[p + 1]) << 8) }
    private func s16(_ p: Int) -> Int { let v = u16(p); return v >= 0x8000 ? v - 0x10000 : v }
    private func u32(_ p: Int) -> UInt32 {
        UInt32(buf[p]) | (UInt32(buf[p + 1]) << 8) | (UInt32(buf[p + 2]) << 16) | (UInt32(buf[p + 3]) << 24)
    }
    private func s32(_ p: Int) -> Int32 { Int32(bitPattern: u32(p)) }

    private func cstr(_ off: Int, _ max: Int) -> String {
        var bytes: [UInt8] = []
        for i in 0..<max {
            let b = buf[off + i]
            if b == 0 { break }
            bytes.append(b)
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
