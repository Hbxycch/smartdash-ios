import Foundation
import CryptoKit

/// 车机 App 的账号接口（/api/v1/user/*），与 Android 端 AccountApi 同口径。
///
/// 与设备上报（CloudSync）分开：上报走设备 token，账号走用户 token，
/// 失败语义完全不同（设备 token 失效要重新激活，用户 token 失效只需重新登录）。
enum AccountApi {

    struct ApiError: Error, LocalizedError {
        let status: Int
        let code: String
        let message: String

        var errorDescription: String? { message }

        /// 把服务端错误码翻译成用户能懂的话
        static func friendly(_ e: ApiError) -> String {
            switch e.code {
            case "USERNAME_TAKEN": return "该用户名已被注册"
            case "PHONE_TAKEN": return "该手机号已注册"
            case "PASSWORD_WEAK": return e.message
            case "BAD_CREDENTIALS": return "用户名或密码不对"
            case "USER_LOCKED": return e.message.isEmpty ? "账号已锁定，稍后再试" : e.message
            case "DEVICE_OCCUPIED": return "本机已绑定其它账号的车，不能凭本账号抢占"
            case "HTTP_404": return "服务器暂未开通账号功能"
            default: return e.message.isEmpty ? "请求失败（\(e.status)）" : e.message
            }
        }
    }

    /// 硬件指纹：同一台机器重装/恢复后尽量认回原来的车。
    /// iOS 没有持久硬件标识，用 identifierForVendor（卸载重装在同机同厂商下保持稳定）。
    static func fingerprint() -> String {
        let id = UIDeviceWrapper.identifierForVendor ?? UUID().uuidString
        let data = Data(id.utf8)
        let digest = SHA256.hash(data: data)
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 接口

    /// 注册：自动 7 天试用，注册即登录（返回用户 token）
    static func register(base: String, username: String, password: String,
                         phone: String, email: String, vehicleModel: String,
                         deviceNo: String, deviceFp: String) async throws -> [String: Any] {
        var body: [String: Any] = [
            "username": username, "password": password, "phone": phone,
        ]
        if !email.isEmpty { body["email"] = email }
        if !vehicleModel.isEmpty { body["vehicleModel"] = vehicleModel }
        if !deviceNo.isEmpty { body["deviceNo"] = deviceNo }
        if !deviceFp.isEmpty { body["deviceFp"] = deviceFp }
        return try await call(base + "/api/v1/user/register", method: "POST", body: body, token: nil)
    }

    static func login(base: String, username: String, password: String,
                      deviceNo: String) async throws -> [String: Any] {
        var body: [String: Any] = ["username": username, "password": password]
        if !deviceNo.isEmpty { body["deviceNo"] = deviceNo }
        return try await call(base + "/api/v1/user/login", method: "POST", body: body, token: nil)
    }

    static func me(base: String, token: String, deviceNo: String) async throws -> [String: Any] {
        var url = base + "/api/v1/user/me"
        if !deviceNo.isEmpty {
            var comp = URLComponents(string: url)
            comp?.queryItems = [URLQueryItem(name: "deviceNo", value: deviceNo)]
            url = comp?.url?.absoluteString ?? url
        }
        return try await call(url, method: "GET", body: nil, token: token)
    }

    static func passwordPolicy(base: String) async throws -> [String: Any] {
        try await call(base + "/api/v1/user/password-policy", method: "GET", body: nil, token: nil)
    }

    /// 认领：把本机 device_no 切到该账号名下原车的 device_no（换屏/换机后找回历史数据）
    static func claim(base: String, token: String, vehicleId: Int,
                      deviceNo: String, deviceFp: String) async throws -> [String: Any] {
        var body: [String: Any] = ["vehicleId": vehicleId, "deviceNo": deviceNo]
        if !deviceFp.isEmpty { body["deviceFp"] = deviceFp }
        return try await call(base + "/api/v1/user/device/claim", method: "POST", body: body, token: token)
    }

    // MARK: - 传输

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    /// 服务端错误体：{"error":{"code":"X","message":"中文原因"}}
    private static func call(_ url: String, method: String,
                             body: [String: Any]?, token: String?) async throws -> [String: Any] {
        guard let u = URL(string: url) else {
            throw ApiError(status: 0, code: "BAD_URL", message: "服务器地址格式不对")
        }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ApiError(status: 0, code: "BAD_RESPONSE", message: "服务器返回异常")
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if !(200..<300).contains(http.statusCode) {
            var code = "HTTP_\(http.statusCode)"
            var msg = "请求失败（\(http.statusCode)）"
            if http.statusCode == 404 { code = "HTTP_404" }
            if let err = json["error"] as? [String: Any] {
                code = err["code"] as? String ?? code
                msg = err["message"] as? String ?? msg
            }
            throw ApiError(status: http.statusCode, code: code, message: msg)
        }
        return json
    }
}

/// 隔离 UIKit 依赖，方便单元测试环境（AccountApi 是 enum，不能放 UIKit 属性）
import UIKit
private enum UIDeviceWrapper {
    static var identifierForVendor: String? {
        UIDevice.current.identifierForVendor?.uuidString
    }
}
