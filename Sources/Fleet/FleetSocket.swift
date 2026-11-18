import Foundation

/// 车队房间 WS 信令客户端（fleet-ws @ NAS:8090），与 Android FleetSocket 同口径。
///
/// 只做三件事，语音不在这（语音走 LiveKit 的 WebRTC 媒体流，不经本连接）：
///   · 聊天收发 / 历史推送
///   · 实时位置广播（5s/帧由 FleetRoomVM 节流后调 sendPosition）
///   · 成员进出通知与花名册
///
/// 断线自动重连（指数退避，5s 起步、上限 30s）；每 20s 发 ping 心跳。
/// 全部回调在主线程。收到 error（token/成员校验失败）时服务端会主动断开，不再重连。
final class FleetSocket: NSObject {

    // MARK: 回调（主线程）
    var onMembers: ((_ items: [[String: Any]]) -> Void)?
    var onChat: ((_ sender: String, _ text: String, _ ts: Double) -> Void)?
    var onPosition: ((_ userId: Int, _ sender: String, _ lat: Double, _ lng: Double,
                      _ spd: Double?, _ ts: Double) -> Void)?
    var onJoin: ((_ userId: Int, _ sender: String) -> Void)?
    var onLeave: ((_ userId: Int, _ sender: String) -> Void)?
    var onClosed: ((_ reason: String) -> Void)?
    var onError: ((_ code: String, _ message: String) -> Void)?

    private var url = ""
    private var token = ""
    private var room = ""

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        return URLSession(configuration: cfg, delegate: nil, delegateQueue: nil)
    }()
    private var task: URLSessionWebSocketTask?
    private var wantConnected = false
    private var backoff: TimeInterval = 5
    private var pingTimer: Timer?

    // MARK: 连接

    func connect(url: String, token: String, room: String) {
        self.url = url
        self.token = token
        self.room = room
        open()
    }

    private func open() {
        guard wantConnected, !url.isEmpty, !room.isEmpty,
              var comps = URLComponents(string: url) else { return }
        let item = URLQueryItem(name: "token", value: token)
        comps.queryItems = (comps.queryItems ?? []) + [item, URLQueryItem(name: "room", value: room)]
        guard let u = comps.url else { return }

        let t = session.webSocketTask(with: u)
        task = t
        t.resume()
        backoff = 5
        startPing()
        receiveLoop(t)
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.task?.sendPing(pongReceiveHandler: { _ in })
        }
    }

    /// 持续收包；连接断开时按退避重连
    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, self.task === t, self.wantConnected else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let text): self.handle(text)
                case .data(let d):
                    if let text = String(data: d, encoding: .utf8) { self.handle(text) }
                @unknown default: break
                }
                self.receiveLoop(t)
            case .failure:
                self.scheduleReconnect(reason: "连接断开，正在重连…")
            }
        }
    }

    private func scheduleReconnect(reason: String) {
        guard wantConnected else { return }
        pingTimer?.invalidate()
        task = nil
        DispatchQueue.main.async { [weak self] in
            self?.onClosed?(reason)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff) { [weak self] in
            guard let self, self.wantConnected else { return }
            self.backoff = min(self.backoff * 2, 30)
            self.open()
        }
    }

    func close() {
        wantConnected = false
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: "bye".data(using: .utf8))
        task = nil
    }

    // MARK: 发送

    /// 聊天文本（服务端落库后广播，含发送者自己）
    func sendChat(_ text: String) {
        send(["t": "chat", "text": text])
    }

    /// 实时位置上报
    func sendPosition(lat: Double, lng: Double, spd: Double?) {
        var o: [String: Any] = ["t": "pos", "lat": lat, "lng": lng]
        if let spd { o["spd"] = spd }
        send(o)
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    // MARK: 收包解析（与 Android FleetSocket.handle 同字段）

    private func handle(_ text: String) {
        guard let m = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch m["t"] as? String {
            case "chat":
                self.onChat?(m["sender"] as? String ?? "",
                             m["text"] as? String ?? "",
                             m["ts"] as? Double ?? 0)
            case "pos":
                self.onPosition?(m["userId"] as? Int ?? 0,
                                 m["sender"] as? String ?? "",
                                 m["lat"] as? Double ?? 0,
                                 m["lng"] as? Double ?? 0,
                                 m["spd"] as? Double,
                                 m["ts"] as? Double ?? 0)
            case "members":
                self.onMembers?(m["items"] as? [[String: Any]] ?? [])
            case "join":
                self.onJoin?(m["userId"] as? Int ?? 0, m["sender"] as? String ?? "")
            case "leave":
                self.onLeave?(m["userId"] as? Int ?? 0, m["sender"] as? String ?? "")
            case "error":
                self.wantConnected = false    // token/成员校验失败，不再重连
                self.onError?(m["code"] as? String ?? "", m["message"] as? String ?? "")
            default: break                    // pong 等
            }
        }
    }
}
