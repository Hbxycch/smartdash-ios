import Foundation
import Darwin

/// 崩溃捕获：未捕获异常 + 致命信号都落盘到 Documents/crash_log.txt，
/// 设置页里可分享出来。闪退类的线上问题只能靠这个拿到调用栈。
///
/// 注意：信号处理器里只能用可重入的最低级 API，这里只用 open/write/backtrace。
final class CrashLogger {

    static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("crash_log.txt")
    }

    static var fileSize: Int {
        ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int) ?? 0
    }

    /// 信号处理器里要用的 C 路径，install 时准备好，避免处理器内部分配内存
    private static var cPath: UnsafeMutablePointer<CChar>?

    static func install() {
        cPath = strdup(fileURL.path)

        NSSetUncaughtExceptionHandler(handleException)

        for sig in [SIGABRT, SIGSEGV, SIGILL, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig, handleSignal)
        }
        mark("──── 启动 ────")
    }

    /// 关键节点埋点，崩溃后能看出走到哪一步
    static func mark(_ text: String) {
        append("• \(text)")
    }

    static func append(_ text: String) {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss.SSS"
        let line = "\(df.string(from: Date())) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
        // 崩溃日志同时写进蓝牙日志，用户只发一个文件就够
        BtLog.log("[crash] \(text)")
    }

    static func clear() {
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func tailLines(_ n: Int) -> String {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty else {
            return "（暂无崩溃记录）"
        }
        return content.split(separator: "\n", omittingEmptySubsequences: false).suffix(n).joined(separator: "\n")
    }
}

// 信号处理器必须是非捕获的 C 函数，单独放全局作用域
private func handleSignal(_ sig: Int32) {
    CrashLogger.writeSignalCrash(sig)
    signal(sig, SIG_DFL)
    raise(sig)                       // 交回系统，仍会生成标准 .ips 崩溃报告
}

private func handleException(_ ex: NSException) {
    let stack = ex.callStackSymbols.joined(separator: "\n")
    CrashLogger.append("‼️ NSException \(ex.name.rawValue): \(ex.reason ?? "无原因")\n\(stack)")
}

extension CrashLogger {
    /// 只用最低级 API 写盘（信号上下文安全）
    static func writeSignalCrash(_ sig: Int32) {
        guard let path = cPath else { return }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        let name: String
        switch sig {
        case SIGABRT: name = "SIGABRT"
        case SIGSEGV: name = "SIGSEGV"
        case SIGILL: name = "SIGILL"
        case SIGFPE: name = "SIGFPE"
        case SIGBUS: name = "SIGBUS"
        case SIGTRAP: name = "SIGTRAP"
        default: name = "SIGNAL(\(sig))"
        }
        let header = "\n‼️ 崩溃信号 \(name) —— 调用栈如下\n"
        _ = header.withCString { write(fd, $0, strlen($0)) }

        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let n = backtrace(&frames, 64)
        backtrace_symbols_fd(frames, n, fd)
        close(fd)
    }
}
