import Foundation

/// 高德 SDK 的全局初始化。Key 从 Info.plist 的 AMapAPIKey 读取（CI 用 Secret 注入，不进仓库）。
enum AMapBootstrap {

    static var key: String {
        (Bundle.main.object(forInfoDictionaryKey: "AMapAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var configured: Bool { !key.isEmpty }

    private static var started = false

    /// 必须在任何 AMap 类被使用之前调用一次（App 启动时）。
    static func start() {
        guard !started, configured else { return }
        started = true
        AMapServices.shared().enableHTTPS = true
        AMapServices.shared().apiKey = key
    }
}
