import Foundation
import UIKit
import CoreLocation

/// 云端上报：激活（enroll）、采样入队、批量上传、失败退避。
///
/// 数据流：BmsService/LocationService → 按服务端节奏采样 → 写本地 JSONL 队列
///        → 定时批量 POST → 成功才从队列删除。
/// 时钟：用服务端返回的 serverTs 算偏移，超过 60 秒在设置页提示。
///
/// 说明：这里用普通 URLSession（waitsForConnectivity）。
/// 真正锁屏后的后台续传需要 background configuration，等上报链路稳定后再切，
/// 现在队列落盘 + 退避重试已经保证「不丢数据」，只是补传会等下次前台。
final class CloudSync: ObservableObject {

    enum Phase: Equatable {
        case off
        case needConfig
        case enrolling
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .off: return "未启用"
            case .needConfig: return "待配置"
            case .enrolling: return "正在激活"
            case .ready: return "已激活"
            case .failed: return "上传异常"
            }
        }
    }

    enum CloudError: LocalizedError {
        case badURL
        case badResponse
        case unauthorized
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "服务器地址格式不对"
            case .badResponse: return "服务器返回的不是预期的 JSON"
            case .unauthorized: return "设备令牌失效，需要重新激活"
            case .server(let code, let body):
                let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return "HTTP \(code) \(t.prefix(100))"
            }
        }
    }

    private struct BatchResult {
        var accepted = 0
        var duplicates = 0
        var rejected = 0
    }

    private enum Key {
        static let enabled = "cloud_enabled"
        static let base = "cloud_base_url"
        static let code = "cloud_code"
        static let token = "cloud_token"
        static let deviceNo = "cloud_device_no"
        static let telInterval = "cloud_tel_interval"
        static let trackInterval = "cloud_track_interval"
    }

    // MARK: - 出厂默认值（用户清空后回落，保证开箱即可用）

    public enum Defaults {
        /// 云同步服务器根地址（不带 /api/v1）
        public static let server = "https://smartdash-web.w.zood.org:8888"
        /// OTA 升级清单（启动时检查更新用）
        public static let manifest = "https://smartdash-web.w.zood.org:8888/ota/version.json"
    }

    // MARK: - 用户可改的配置

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Key.enabled)
            if enabled {
                syncPhase()
                kick()
            } else {
                stopTimer()
                phase = .off
            }
        }
    }

    @Published var baseURL: String {
        didSet {
            UserDefaults.standard.set(baseURL, forKey: Key.base)
            syncPhase()
        }
    }

    @Published var code: String {
        didSet { UserDefaults.standard.set(code, forKey: Key.code) }
    }

    // MARK: - 只读状态

    @Published private(set) var phase: Phase = .off
    @Published private(set) var statusText = ""
    @Published private(set) var pendingTelemetry = 0
    @Published private(set) var pendingTrack = 0
    @Published private(set) var lastUpload: Date?
    @Published private(set) var deviceNo = ""
    @Published private(set) var telemetryIntervalS = 10
    @Published private(set) var trackIntervalS = 10
    @Published private(set) var clockSkewS = 0

    var pendingTotal: Int { pendingTelemetry + pendingTrack }
    var isActivated: Bool { !token.isEmpty }
    var isOn: Bool { enabled }

    // MARK: - 内部

    private var token: String
    private let telemetryQueue = UploadQueue(kind: .telemetry)
    private let trackQueue = UploadQueue(kind: .track)

    private weak var bms: BmsService?
    private weak var location: LocationService?
    private weak var settings: AppSettings?

    private var timer: Timer?
    private var flushing = false
    private var failStreak = 0
    private var backoffUntil = Date.distantPast
    private var enrollRetryAfter = Date.distantPast
    private var lastSampleAt = Date.distantPast
    private var lastTrackAt = Date.distantPast
    private var lastCellsAt = Date.distantPast
    private var lastTrackCoord: (lat: Double, lng: Double)?
    private var observingForeground = false

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.allowsCellularAccess = true
        return URLSession(configuration: cfg)
    }()

    init() {
        let d = UserDefaults.standard
        // 云同步默认打开（v4.11 起）：地址已出厂预填，装上即可上报；
        // 用户手动关过就以用户为准。地址清空时回落默认。
        enabled = d.object(forKey: Key.enabled) as? Bool ?? true
        let savedBase = d.string(forKey: Key.base) ?? ""
        baseURL = savedBase.trimmingCharacters(in: .whitespaces).isEmpty
            ? Defaults.server : savedBase
        code = d.string(forKey: Key.code) ?? ""
        token = d.string(forKey: Key.token) ?? ""
        telemetryIntervalS = max(5, d.object(forKey: Key.telInterval) as? Int ?? 10)
        trackIntervalS = max(5, d.object(forKey: Key.trackInterval) as? Int ?? 10)

        var no = d.string(forKey: Key.deviceNo) ?? ""
        if no.isEmpty {
            no = Self.makeDeviceNo()
            d.set(no, forKey: Key.deviceNo)
        }
        deviceNo = no

        if enabled {
            phase = (token.isEmpty || baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                ? .needConfig : .ready
        }
        refreshCounts()
    }

    /// 由 RootView 在首屏注入依赖（单例生命周期与 App 一致，弱引用避免循环）
    func start(bms: BmsService, location: LocationService, settings: AppSettings) {
        self.bms = bms
        self.location = location
        self.settings = settings
        refreshCounts()
        if !observingForeground {
            observingForeground = true
            // 回到前台立刻补传一次，别等定时器
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        if enabled { kick() }
    }

    // MARK: - 对外操作

    /// 激活：仅在未激活（token 为空）时可用。
    /// 已激活时后端会拒绝重复用码（一次性凭证也已被消费），UI 层按钮同步禁用；
    /// token 失效（上报收到 401/403 会清空 token）后自动恢复可点。
    func activate() {
        guard !isActivated else { return }
        Task { await enroll() }
    }

    func uploadNow() {
        backoffUntil = .distantPast
        failStreak = 0
        Task { await flush() }
    }

    func clearQueues() {
        telemetryQueue.clear()
        trackQueue.clear()
        refreshCounts()
        statusText = "本地待传数据已清空"
    }

    // MARK: - 定时循环

    private func kick() {
        stopTimer()
        guard enabled else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard enabled else { return }
        autoEnrollIfNeeded()

        guard !normalizedBaseURL.isEmpty else { return }

        let now = Date()
        sampleIfDue(now: now)

        if now >= backoffUntil, !flushing, pendingTelemetry + pendingTrack > 0 {
            Task { await flush() }
        }
        refreshCounts()
    }

    private func sampleIfDue(now: Date) {
        if now.timeIntervalSince(lastSampleAt) >= Double(telemetryIntervalS) {
            if captureTelemetry(now: now) { lastSampleAt = now }
        }
        if now.timeIntervalSince(lastTrackAt) >= Double(trackIntervalS) {
            if captureTrack(now: now) { lastTrackAt = now }
        }
    }

    // MARK: - 采样

    @discardableResult
    private func captureTelemetry(now: Date) -> Bool {
        guard let bms, let updated = bms.snapshot.lastUpdate,
              now.timeIntervalSince(updated) < 5 else { return false }   // 5 秒内没新数据 = 没连着

        let ts = Int(now.timeIntervalSince1970 * 1000)
        // 逐串电压 5 分钟带一次：NCHAR(512) 放不下 32 串的高频快照
        let withCells = now.timeIntervalSince(lastCellsAt) >= 300
        guard let dict = TelemetryMapping.sample(from: bms.snapshot, ts: ts, withCells: withCells),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let line = String(data: data, encoding: .utf8) else { return false }

        telemetryQueue.append(line)
        if withCells { lastCellsAt = now }
        return true
    }

    @discardableResult
    private func captureTrack(now: Date) -> Bool {
        guard let location, location.hasFix, location.accuracy >= 0 else { return false }
        let c = location.coordinate

        // 静止不发：位移 < 20m 且速度 < 3 km/h（契约里的停发规则）
        if let last = lastTrackCoord {
            let moved = CLLocation(latitude: last.lat, longitude: last.lng)
                .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            if moved < 20, location.speedKmh < 3 { return false }
        }

        let ts = Int(now.timeIntervalSince1970 * 1000)
        guard let dict = TelemetryMapping.point(lat: c.latitude, lng: c.longitude,
                                                speed: location.speedKmh, heading: location.heading,
                                                acc: location.accuracy, alt: location.altitude, ts: ts),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let line = String(data: data, encoding: .utf8) else { return false }

        trackQueue.append(line)
        lastTrackCoord = (c.latitude, c.longitude)
        return true
    }

    // MARK: - 上传

    @MainActor
    private func flush() async {
        guard !flushing else { return }
        guard !token.isEmpty, !normalizedBaseURL.isEmpty else { return }
        flushing = true
        defer { flushing = false }

        await uploadTelemetry()
        await uploadTrack()
        refreshCounts()
    }

    @MainActor
    private func uploadTelemetry() async {
        var rounds = 0
        while rounds < 5 {                       // 一次最多连发 5 批，避免积压一次怼上去
            rounds += 1
            let lines = telemetryQueue.peek(200)  // 单批 ≤ 500 且 ≤ 512KB，200 条留足余量
            guard !lines.isEmpty else { return }

            let samples: [[String: Any]] = lines.compactMap { line in
                guard let d = line.data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            }
            guard !samples.isEmpty else { telemetryQueue.drop(lines.count); return }

            do {
                let r = try await post("/telemetry/batch",
                                       body: ["batchId": UUID().uuidString, "samples": samples])
                telemetryQueue.drop(lines.count)
                markSuccess()
                var text = "遥测已上传 \(r.accepted) 条"
                if r.duplicates > 0 { text += "，重复 \(r.duplicates)" }
                if r.rejected > 0 { text += "，拒收 \(r.rejected)（已丢弃）" }
                statusText = text
            } catch {
                handle(error)
                return
            }
        }
    }

    @MainActor
    private func uploadTrack() async {
        var rounds = 0
        while rounds < 5 {
            rounds += 1
            let lines = trackQueue.peek(500)
            guard !lines.isEmpty else { return }

            let points: [[String: Any]] = lines.compactMap { line in
                guard let d = line.data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            }
            guard !points.isEmpty else { trackQueue.drop(lines.count); return }

            do {
                let r = try await post("/track/batch",
                                       body: ["batchId": UUID().uuidString, "points": points])
                trackQueue.drop(lines.count)
                markSuccess()
                if r.accepted > 0 { statusText = "轨迹已上传 \(r.accepted) 点" }
            } catch {
                handle(error)
                return
            }
        }
    }

    @MainActor
    private func markSuccess() {
        lastUpload = Date()
        failStreak = 0
        if case .failed = phase { phase = .ready }
        if phase != .ready, !token.isEmpty { phase = .ready }
    }

    @MainActor
    private func handle(_ error: Error) {
        if case CloudError.unauthorized = error {
            token = ""
            UserDefaults.standard.removeObject(forKey: Key.token)
            phase = .needConfig
            statusText = "设备令牌失效，请重新填授权码激活"
            return
        }
        failStreak += 1
        let delay = Self.backoff(failStreak)
        backoffUntil = Date().addingTimeInterval(delay)
        phase = .failed(error.localizedDescription)
        statusText = "上传失败，\(Int(delay)) 秒后重试：\(error.localizedDescription)"
    }

    private static func backoff(_ n: Int) -> TimeInterval {
        switch n {
        case 1: return 30         // 契约：30s → 2m → 5m → 15m，之后每 15 分钟
        case 2: return 120
        case 3: return 300
        default: return 900
        }
    }

    // MARK: - 网络

    @MainActor
    private func post(_ path: String, body: [String: Any]) async throws -> BatchResult {
        guard let url = URL(string: normalizedBaseURL + "/api/v1" + path) else {
            throw CloudError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CloudError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudError.badResponse
        }

        var r = BatchResult()
        r.accepted = obj["accepted"] as? Int ?? 0
        r.duplicates = obj["duplicates"] as? Int ?? 0
        r.rejected = (obj["rejected"] as? [Any])?.count ?? 0

        if let serverTs = obj["serverTs"] as? Int {
            let local = Int(Date().timeIntervalSince1970 * 1000)
            clockSkewS = (serverTs - local) / 1000
        }
        return r
    }

    @MainActor
    func enroll() async {
        guard enabled else { return }
        // 归一化：大小写/空格/连字符差异在这里抹平（与服务端 enroll 一致）
        let trimmed = AuthCode.normalize(code)
        let base = normalizedBaseURL
        guard !trimmed.isEmpty, !base.isEmpty else {
            phase = .needConfig
            statusText = "请先填服务器地址和授权码"
            return
        }

        phase = .enrolling
        statusText = "正在用授权码激活…"

        do {
            // 用户登录后上报会带用户身份：激活码校验 issued_user_id，
            // 设备归属（owner_user_id）也在这里落库——数据跟设备走，登录只决定可见性
            let userToken = settings?.userToken ?? ""
            var body: [String: Any] = [
                "code": trimmed,
                "device_no": deviceNo,
                // 注册时填了车型就用它，否则用默认
                "model": (settings?.deviceModelHint.isEmpty ?? true)
                    ? "SmartDash-T3" : (settings?.deviceModelHint ?? "SmartDash-T3"),
                "bms_vendor": settings?.vendor.rawValue ?? "ant",
                "platform": "ios",
                "device_fp": AccountApi.fingerprint(),
            ]
            if let fw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                body["fw_version"] = fw
            }

            guard let url = URL(string: base + "/api/v1/device/enroll") else { throw CloudError.badURL }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            if !userToken.isEmpty {
                req.setValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw CloudError.badResponse }
            guard (200..<300).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                throw CloudError.server(http.statusCode, Self.friendlyEnrollError(text))
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let newToken = obj["deviceToken"] as? String, !newToken.isEmpty else {
                throw CloudError.badResponse
            }

            token = newToken
            UserDefaults.standard.set(newToken, forKey: Key.token)
            if let no = obj["deviceNo"] as? String, !no.isEmpty {
                deviceNo = no
                UserDefaults.standard.set(no, forKey: Key.deviceNo)
            }
            if let v = obj["telemetryIntervalS"] as? Int, v >= 5 {
                telemetryIntervalS = v
                UserDefaults.standard.set(v, forKey: Key.telInterval)
            }
            if let v = obj["trackIntervalS"] as? Int, v >= 5 {
                trackIntervalS = v
                UserDefaults.standard.set(v, forKey: Key.trackInterval)
            }

            failStreak = 0
            backoffUntil = .distantPast
            phase = .ready
            statusText = "已激活，设备号 \(deviceNo)"
            refreshUserState()      // 激活成功异步刷 /me：绑定车辆名 + 试用天数立即变对
        } catch {
            phase = .failed(error.localizedDescription)
            statusText = "激活失败：\(error.localizedDescription)"
        }
    }

    private func autoEnrollIfNeeded() {
        guard enabled, token.isEmpty, phase != .enrolling else { return }
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard !normalizedBaseURL.isEmpty else { return }
        guard Date() >= enrollRetryAfter else { return }
        enrollRetryAfter = Date().addingTimeInterval(30)   // 失败也别每秒重试
        Task { await enroll() }
    }

    /// 激活成功后刷新账号态（与 Android CloudSync.refreshUserState 同口径）：
    /// 拉一次 /me，把剩余试用天数与本机绑定车辆名写回偏好。
    /// 失败静默——只是刷新展示，不影响激活结果；SwiftUI 会随 @Published 自动重绘。
    private func refreshUserState() {
        guard let settings, !settings.userToken.isEmpty else { return }
        let base = normalizedBaseURL
        let no = deviceNo
        Task { @MainActor in
            do {
                let me = try await AccountApi.me(base: base, token: settings.userToken, deviceNo: no)
                if let u = me["user"] as? [String: Any],
                   let trial = u["trialDaysLeft"] as? Int, trial >= 0 {
                    settings.userTrialDays = trial
                }
                var boundName = ""
                if let dev = me["device"] as? [String: Any], dev["bound"] as? Bool == true,
                   let v = dev["vehicle"] as? [String: Any],
                   let model = v["model"] as? String {
                    boundName = model
                }
                settings.boundVehicle = boundName
            } catch {
                // 网络失败沿用本地缓存，不打扰用户
            }
        }
    }

    // MARK: - 杂项

    /// 用户可能填 `192.168.7.252:8081`、`http://x/api/v1/`、带末尾斜杠的各种形态
    var normalizedBaseURL: String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/api/v1") { s = String(s.dropLast("/api/v1".count)) }
        return s
    }

    private func syncPhase() {
        guard enabled else { phase = .off; return }
        if token.isEmpty || normalizedBaseURL.isEmpty {
            phase = .needConfig
        } else if case .failed = phase {
            // 保留错误，别把「上传异常」冲掉
        } else {
            phase = .ready
        }
    }

    private func refreshCounts() {
        let t = telemetryQueue.pending
        let k = trackQueue.pending
        if t != pendingTelemetry { pendingTelemetry = t }
        if k != pendingTrack { pendingTrack = k }
    }

    private static func friendlyEnrollError(_ text: String) -> String {
        if text.contains("CODE_INVALID") { return "授权码不存在或已作废" }
        if text.contains("CODE_USED") { return "授权码已被别的设备使用" }
        if text.contains("CODE_EXPIRED") { return "授权码已过期" }
        if text.contains("DEVICE_TAKEN") { return "该设备号已绑定其它授权码，需后台解绑" }
        if text.contains("DEVICE_OCCUPIED") { return "本机已绑定其它账号的车，不能凭本账号抢占。请让原账号在设置里解绑，或联系管理员转移" }
        return text
    }

    /// 设备号：SD- 年月 + 6 位随机。用蓝牙 MAC 不行（iOS 拿不到）。
    private static func makeDeviceNo() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMM"
        var tail = ""
        for _ in 0..<6 { tail.append(String(Int.random(in: 0...9))) }
        return "SD-\(f.string(from: Date()))-\(tail)"
    }
}
