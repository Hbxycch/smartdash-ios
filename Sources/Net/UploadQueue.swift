import Foundation

/// 待上传队列：磁盘上一行一条 JSON（JSONL）。
///
/// 设计取舍：先落盘、再上报、成功才删除。这样断网/锁屏/进程被系统杀掉都不会丢数据，
/// 补传时用的还是采集时刻的 ts（服务端按 device_no+ts 幂等，重发不会写重）。
struct UploadQueue {
    enum Kind: String {
        case telemetry
        case track
    }

    private let fileURL: URL
    private let lock = NSLock()

    init(kind: Kind) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("UploadQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("\(kind.rawValue).jsonl")
    }

    /// 待上传条数（读文件，1 秒一次的量级完全够用）
    var pending: Int {
        lock.lock(); defer { lock.unlock() }
        return readLines().count
    }

    func append(_ json: String) {
        lock.lock(); defer { lock.unlock() }
        guard let data = (json + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // 首次写入（文件还不存在），或者上一步拿不到句柄
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 取最前面 n 条，不删除
    func peek(_ n: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(readLines().prefix(n))
    }

    /// 上报成功后删除最前面 n 条
    func drop(_ n: Int) {
        lock.lock(); defer { lock.unlock() }
        var lines = readLines()
        guard !lines.isEmpty else { return }
        lines.removeFirst(min(n, lines.count))
        writeLines(lines)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 内部

    private func readLines() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func writeLines(_ lines: [String]) {
        guard !lines.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(to: fileURL, options: .atomic)
    }
}
