import Foundation
import UIKit

/// 头像三级缓存（对齐 Android AvatarStore）：内存 NSCache → 磁盘 caches/avatars → 网络带鉴权拉取。
///
/// key 直接用完整 URL（服务端 avatar_ver 变化会带新的 ?v=，URL 变了自然穿透缓存）。
/// 全部回调主线程；登出 / 移除头像时 drop 清对应缓存。
final class AvatarStore {
    static let shared = AvatarStore()

    private let mem = NSCache<NSString, UIImage>()
    private let dir: URL
    private let session: URLSession
    private var inflight: [String: [(UIImage?) -> Void]] = [:]

    private init() {
        mem.countLimit = 64
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    /// 异步取头像；失败回传 nil（调用方保留首字母兜底）
    func load(_ urlString: String, token: String, completion: @escaping (UIImage?) -> Void) {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { completion(nil); return }
        let key = urlString as NSString

        if let hit = mem.object(forKey: key) { completion(hit); return }

        let diskPath = dir.appendingPathComponent(diskKey(urlString))
        if let img = UIImage(contentsOfFile: diskPath.path) {
            mem.setObject(img, forKey: key)
            completion(img)
            return
        }

        // 同一 URL 并发去重
        inflight[urlString, default: []].append(completion)
        guard inflight[urlString]?.count == 1 else { return }

        var req = URLRequest(url: url)
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        session.dataTask(with: req) { [weak self] data, _, _ in
            var img: UIImage?
            if let data, !data.isEmpty, let decoded = UIImage(data: data) {
                img = decoded
                try? data.write(to: diskPath)
                self?.mem.setObject(decoded, forKey: key)
            }
            DispatchQueue.main.async {
                let cbs = self?.inflight[urlString] ?? []
                self?.inflight.removeValue(forKey: urlString)
                cbs.forEach { $0(img) }
            }
        }.resume()
    }

    /// 登出 / 移除头像：清内存与磁盘（全清，key 含 ?v= 逐条删意义不大）
    func dropAll() {
        mem.removeAllObjects()
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    /// URL 里常有 ?v=、/ 等不适合做文件名的字符，落盘用稳定散列
    private func diskKey(_ urlString: String) -> String {
        let data = Data(urlString.utf8)
        let digest = SHA256.hash(data: data)
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".img"
    }
}

import CryptoKit
