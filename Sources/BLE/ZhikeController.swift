import Foundation

/// 智科 GEKOO 控制器 BLE 实时帧解析（与 Android 端 zhike/ZhikeController.java 同一套标定）。
///
/// 帧结构：帧头 AA 13 00 + 31 个小端 16 位数据字 w0..w30 + 校验字 w31
///        校验：sum(w0..w31) & 0xFFFF == 0xFFFF
///   w6  电机转速 = 直接读数 rpm（不要除 5.46）
///   w8  母线电压 = w8 × 150 / 4096 / 10 V
///   w9  母线电流 int16 A（负 = 滑行/回充）
///   w18 控制器温度 = w18 / 100 ℃
///   w7  相线电流 ≈ w7 × 0.0045 A（仅稳态巡航近似）
///   w22 故障位图；w21 bit8 = 回充/再生制动
final class ZhikeController {

    static let frameLen = 67
    static let wordCount = 32

    // ── 最近一帧的解码结果 ──
    private(set) var lastUpdate: Date?
    private(set) var rpm: Double = 0
    private(set) var busVoltageV: Double = 0
    private(set) var busCurrentA: Double = 0
    /// 控制器温度；nil 表示该帧没给出
    private(set) var controllerTempC: Double?
    /// 相线电流估算；nil 表示无有效值（回充/静止）
    private(set) var phaseCurrentA: Double?
    private(set) var faultBits = 0
    private(set) var regen = false
    private(set) var frameCount = 0
    private(set) var checksumErrors = 0

    var hasTemp: Bool { controllerTempC != nil }

    /// 数据是否新鲜（3 秒内收到过有效帧）
    var isFresh: Bool {
        guard let t = lastUpdate else { return false }
        return Date().timeIntervalSince(t) < 3
    }

    /// 解析一帧（67 字节起）；校验通过则更新字段并返回 true
    @discardableResult
    func decode(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= Self.frameLen else { return false }
        guard bytes[0] == 0xAA, bytes[1] == 0x13, bytes[2] == 0x00 else { return false }

        var w = [Int](repeating: 0, count: Self.wordCount)
        var sum = 0
        for n in 0..<Self.wordCount {
            let off = 3 + 2 * n
            let v = Int(bytes[off]) | (Int(bytes[off + 1]) << 8)
            w[n] = v
            sum = (sum + v) & 0xFFFF
        }
        guard sum == 0xFFFF else {
            checksumErrors += 1
            return false
        }

        frameCount += 1
        lastUpdate = Date()

        rpm = Double(Int16(bitPattern: UInt16(truncatingIfNeeded: w[6])))
        busVoltageV = Double(w[8]) * 150 / 4096 / 10
        busCurrentA = Double(Int16(bitPattern: UInt16(truncatingIfNeeded: w[9])))

        let t18 = w[18]
        controllerTempC = (t18 > 0 && t18 <= 20000) ? Double(t18) / 100 : nil

        let w7 = Int16(bitPattern: UInt16(truncatingIfNeeded: w[7]))
        phaseCurrentA = w7 > 0 ? Double(w7) * 0.0045 : nil

        faultBits = w[22]
        regen = ((w[21] >> 8) & 1) == 1
        return true
    }

    func reset() {
        lastUpdate = nil
        rpm = 0
        busVoltageV = 0
        busCurrentA = 0
        controllerTempC = nil
        phaseCurrentA = nil
        faultBits = 0
        regen = false
        frameCount = 0
        checksumErrors = 0
    }

    static func checksumOK(_ frame: [UInt8]) -> Bool {
        guard frame.count >= frameLen else { return false }
        var sum = 0
        for n in 0..<wordCount {
            let off = 3 + 2 * n
            sum = (sum + Int(frame[off]) + (Int(frame[off + 1]) << 8)) & 0xFFFF
        }
        return sum == 0xFFFF
    }

    // ═══ 拆包 / 重同步 ═══
    /// 按「帧头定位 → 校验通过才收」重组；坏帧丢一位滑动重找。
    /// iOS 的 MTU 通常够大，一般一次通知就是一整帧，这里只是兜底。
    final class Assembler {
        private var buf: [UInt8] = []
        private let limit = 4096

        func reset() { buf.removeAll(keepingCapacity: true) }

        func feed(_ data: [UInt8]) -> [[UInt8]] {
            guard !data.isEmpty else { return [] }
            buf.append(contentsOf: data)
            if buf.count > limit { buf.removeFirst(buf.count - limit) }

            var out: [[UInt8]] = []
            var cursor = 0
            while cursor < buf.count {
                guard let head = findHeader(from: cursor) else {
                    cursor = max(cursor, buf.count - 2)
                    break
                }
                cursor = head
                if buf.count - cursor < ZhikeController.frameLen { break }

                let frame = Array(buf[cursor..<(cursor + ZhikeController.frameLen)])
                if frame[0] == 0xAA, frame[1] == 0x13, frame[2] == 0x00,
                   ZhikeController.checksumOK(frame) {
                    out.append(frame)
                    cursor += ZhikeController.frameLen
                } else {
                    cursor += 1
                }
            }
            if cursor > 0 {
                if cursor >= buf.count { buf.removeAll(keepingCapacity: true) }
                else { buf.removeFirst(cursor) }
            }
            return out
        }

        private func findHeader(from: Int) -> Int? {
            var i = max(0, from)
            while i + 3 <= buf.count {
                if buf[i] == 0xAA, buf[i + 1] == 0x13, buf[i + 2] == 0x00 { return i }
                i += 1
            }
            return nil
        }
    }
}
