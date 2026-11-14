import Foundation
import Combine

struct UpdateInfo: Identifiable {
    let id = UUID()
    var versionCode: Int
    var versionName: String
    var downloadURL: URL?
    var changelog: String
    var force: Bool
}

/// 在线升级检查。
///
/// iOS 不能像 Android 那样下载 APK 自己装：正式渠道走 TestFlight / App Store，
/// 自签渠道由电脑端（Sideloadly / AltStore）重装。所以这里只负责
/// 「发现新版本 → 展示更新说明 → 跳转下载页」，安装交给系统或电脑端。
final class UpdateChecker: ObservableObject {

    @Published var checking = false
    @Published var latest: UpdateInfo?
    @Published var errorText: String?

    /// 清单格式与 Android 的 version.json 兼容：
    /// { versionCode, versionName, apkUrl|ipaUrl|url, changelog, force }
    func check(manifestURL: String, currentBuild: Int) {
        let trimmed = manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), !trimmed.isEmpty else {
            errorText = "未配置更新清单地址"
            return
        }
        checking = true
        errorText = nil
        latest = nil

        URLSession.shared.dataTask(with: url) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                if let err {
                    self.errorText = "检查失败：\(err.localizedDescription)"
                    return
                }
                guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.errorText = "清单解析失败（需要 JSON）"
                    return
                }
                let code = (obj["versionCode"] as? Int) ?? Int(obj["versionCode"] as? String ?? "") ?? 0
                let name = obj["versionName"] as? String ?? "?"
                let raw = (obj["ipaUrl"] as? String) ?? (obj["apkUrl"] as? String) ?? (obj["url"] as? String) ?? ""
                let log = obj["changelog"] as? String ?? ""
                let force = obj["force"] as? Bool ?? false

                guard code > currentBuild else {
                    self.errorText = "已是最新版本（\(name)）"
                    return
                }
                self.latest = UpdateInfo(versionCode: code,
                                         versionName: name,
                                         downloadURL: URL(string: raw),
                                         changelog: log,
                                         force: force)
            }
        }.resume()
    }

    func dismiss() { latest = nil }

    /// 当前安装包的版本号（与 project.yml 的 CURRENT_PROJECT_VERSION 一致）
    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
