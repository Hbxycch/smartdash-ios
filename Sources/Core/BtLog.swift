import Foundation

/// 蓝牙链路日志：所有连接/断开/收发/解析事件按行写入 Documents/bt_log.txt。
/// 用途：真机上连不上保护板时，把日志文件分享出来即可离线定位协议层问题。
final class BtLog {

    static let shared = BtLog()

    /// 日志文件位置（设置页分享/查看用）
    static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("bt_log.txt")
    }

    private let queue = DispatchQueue(label: "btlog.writer", qos: .utility)
    /// 单文件上限，超过后清空重写（保住最近的），避免无限增长
    private let maxBytes = 512 * 1024

    private init() {}

    static func log(_ text: String) {
        shared.write(text)
    }

    /// 字节数组 → hex，用于收发帧的记录
    static func hex(_ bytes: [UInt8], maxCount: Int = 120) -> String {
        let shown = bytes.prefix(maxCount).map { String(format: "%02X", $0) }.joined(separator: " ")
        return bytes.count > maxCount ? shown + " …(\(bytes.count)B)" : shown
    }

    static func hex(_ data: Data, maxCount: Int = 120) -> String { hex([UInt8](data), maxCount: maxCount) }

    /// 当前文件大小（字节）；文件不存在返回 0
    static var fileSize: Int {
        ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int) ?? 0
    }

    /// 末尾 n 行文本（设置页预览用）
    static func tailLines(_ n: Int) -> String {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return "（暂无日志）" }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(n).joined(separator: "\n")
    }

    static func clear() { shared.reset() }

    // ── 内部 ──

    private func write(_ text: String) {
        // 开关实时读 UserDefaults，避免和 AppSettings 对象图耦合
        guard UserDefaults.standard.object(forKey: "bt_log_enabled") as? Bool ?? true else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let df = DateFormatter()
            df.dateFormat = "MM-dd HH:mm:ss.SSS"
            let line = "\(df.string(from: Date())) \(text)\n"
            let url = Self.fileURL
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            if size > self.maxBytes {
                try? "\(line)".write(to: url, atomically: true, encoding: .utf8)   // 超限重开
            } else if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func reset() {
        queue.async {
            try? "".write(to: Self.fileURL, atomically: true, encoding: .utf8)
        }
    }
}
