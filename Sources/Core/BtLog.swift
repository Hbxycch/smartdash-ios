import Foundation
import UIKit

/// 蓝牙链路日志：BMS / 控制器 / 扫描三条来源统一留痕，按标签着色。
///
/// 落盘：Documents/ble.log（2MB 封顶，超了滚成 ble.1.log）。
/// 导出：Documents/exports/smartdash-ble-<时间>.log，带头部（机型 / 系统 / App 版本），
/// 通过系统分享（可存到「文件」App）发给技术支持即可。
final class BtLog {

    static let shared = BtLog()

    /// 当前日志文件（设置页 / 日志页展示用）
    static var fileURL: URL { documents.appendingPathComponent("ble.log") }
    private static var rotatedURL: URL { documents.appendingPathComponent("ble.1.log") }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var exportsDir: URL {
        documents.appendingPathComponent("exports", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "btlog.writer", qos: .utility)
    /// 单文件上限 2MB：超过后滚到 ble.1.log，保住最近一段
    private let maxBytes = 2 * 1024 * 1024
    /// 内存里留最近 600 行，日志页不用等读盘
    private let memoryLimit = 600
    private var memory: [String] = []

    private init() {}

    // ═══ 打点 ═══

    static func bms(_ text: String) { shared.write(tag: "BMS", text: text) }
    static func ctrl(_ text: String) { shared.write(tag: "CTRL", text: text) }
    static func scan(_ text: String) { shared.write(tag: "SCAN", text: text) }
    static func app(_ text: String) { shared.write(tag: "APP", text: text) }

    /// 兼容旧调用点（未分类）
    static func log(_ text: String) { shared.write(tag: "APP", text: text) }

    static func hex(_ bytes: [UInt8], maxCount: Int = 120) -> String {
        let shown = bytes.prefix(maxCount).map { String(format: "%02X", $0) }.joined(separator: " ")
        return bytes.count > maxCount ? shown + " …(\(bytes.count)B)" : shown
    }

    static func hex(_ data: Data, maxCount: Int = 120) -> String { hex([UInt8](data), maxCount: maxCount) }

    // ═══ 读取 ═══

    static var fileSize: Int {
        ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int) ?? 0
    }

    /// 全量行（供日志页从新到旧展示）
    static func all() -> [String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    static func tailLines(_ n: Int) -> String {
        let lines = all()
        if lines.isEmpty { return "（暂无日志）" }
        return lines.suffix(n).joined(separator: "\n")
    }

    static func summary() -> String {
        let kb = fileSize / 1024
        return "\(all().count) 行 · \(kb) KB"
    }

    // ═══ 导出 / 清空 ═══

    /// 导出到 Documents/exports，返回文件 URL（失败返回 nil）
    static func export() -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let name = "smartdash-ble-\(df.string(from: Date())).log"
        let out = exportsDir.appendingPathComponent(name)

        var body = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        if body.isEmpty { body = "（暂无蓝牙日志）\n" }
        body += "\n---- \(header())\n"
        do {
            try body.write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            return nil
        }
    }

    /// 导出文件头：机型 + 系统 + App 版本 + 时间
    static func header() -> String {
        let info = Bundle.main.infoDictionary
        let ver = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "device=\(UIDevice.current.model) ios=\(UIDevice.current.systemVersion) "
            + "app=\(ver)(\(build)) time=\(df.string(from: Date()))"
    }

    static func clear() { shared.reset() }

    // ═══ 内部 ═══

    private func write(tag: String, text: String) {
        guard UserDefaults.standard.object(forKey: "bt_log_enabled") as? Bool ?? true else { return }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss.SSS"
        let line = "\(df.string(from: Date())) [\(tag)] \(text)"
        queue.async { [weak self] in
            guard let self else { return }
            self.memory.append(line)
            if self.memory.count > self.memoryLimit { self.memory.removeFirst(self.memory.count - self.memoryLimit) }
            self.flush(line)
        }
    }

    private func flush(_ line: String) {
        let url = Self.fileURL
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if size > maxBytes {
            try? FileManager.default.removeItem(at: Self.rotatedURL)
            try? FileManager.default.moveItem(at: url, to: Self.rotatedURL)
        }
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func reset() {
        queue.async {
            self.memory.removeAll()
            try? "".write(to: Self.fileURL, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: Self.rotatedURL)
        }
    }
}
