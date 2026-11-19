import Foundation
import SwiftUI
import CoreLocation
import MapKit

// MARK: - 数据模型

struct FleetMember: Identifiable, Equatable {
    let id: Int
    let username: String
    let nickname: String
    let role: String
    let online: Bool
    var isOwner: Bool { role == "owner" }
    /// 展示名：昵称优先（空则回退用户名），与 Android nameOf 同口径
    var displayName: String {
        let n = nickname.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? username : n
    }

    static func == (l: FleetMember, r: FleetMember) -> Bool {
        l.id == r.id && l.username == r.username && l.nickname == r.nickname
            && l.online == r.online && l.role == r.role
    }
}

struct ChatMsg: Identifiable {
    let id = UUID()
    let sender: String
    let text: String
    let time: String
    let mine: Bool
    let system: Bool
}

struct MemberPos {
    var lat: Double
    var lng: Double
    var spd: Double?
    var name: String
}

// MARK: - 本机定位（车队房间专用，5s 节流上报）

final class FleetGPS: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @Published var speedKmh: Double = 0
    @Published var hasFix = false
    private let manager = CLLocationManager()
    private var lastSent: Date?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    /// 5s 节流：到点返回 true，调用方拿当前值上报
    func shouldReport() -> Bool {
        guard hasFix else { return false }
        if let last = lastSent, Date().timeIntervalSince(last) < 5 { return false }
        lastSent = Date()
        return true
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0,
              Date().timeIntervalSince(loc.timestamp) < 5 else { return }
        coordinate = loc.coordinate
        speedKmh = max(0, loc.speed) * 3.6
        hasFix = true
    }
}

// MARK: - 房间 ViewModel

@MainActor
final class FleetRoomVM: ObservableObject {

    // 车队基础信息
    @Published var roomCode = ""
    @Published var fleetName = ""
    @Published var meId = 0
    @Published var myRole = "member"
    var isOwner: Bool { myRole == "owner" }

    @Published var members: [FleetMember] = []
    @Published var positions: [Int: MemberPos] = [:]
    @Published var chat: [ChatMsg] = []
    @Published var chatVisible = false
    @Published var toast = ""
    @Published var statusChip = ""
    @Published var activeTripId = 0
    @Published var connecting = true

    let gps = FleetGPS()
    let voice = FleetVoice()
    private var socket = FleetSocket()
    private var chatFadeTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var voiceReady = false

    private var base = ""
    private var token = ""

    // MARK: 生命周期

    func start(base: String, token: String, fleet: [String: Any]) {
        self.base = base
        self.token = token
        roomCode = fleet["roomCode"] as? String ?? ""
        fleetName = fleet["name"] as? String ?? ""
        meId = fleet["meId"] as? Int ?? 0
        myRole = fleet["myRole"] as? String ?? "member"
        applyMembers(fleet["members"] as? [[String: Any]] ?? [])
        let trips = fleet["trips"] as? [[String: Any]] ?? []
        activeTripId = trips.first { ($0["active"] as? Bool) == true }?["id"] as? Int ?? 0

        gps.start()
        connectSocket()
        loadChatHistory()
        Task { await connectVoice() }
    }

    func stop() {
        socket.close()
        gps.stop()
        voice.disconnect()
        chatFadeTask?.cancel()
        toastTask?.cancel()
    }

    // MARK: WS

    private func connectSocket() {
        guard let fleetPayload = cachedFleet else { return }
        let wsUrl = fleetPayload["wsUrl"] as? String ?? ""
        guard !wsUrl.isEmpty, !roomCode.isEmpty else {
            statusChip = "信令地址未配置"
            connecting = false
            return
        }
        socket = FleetSocket()
        socket.onMembers = { [weak self] items in self?.applyMembers(items) }
        socket.onChat = { [weak self] sender, text, ts in
            self?.addChatRow(sender: sender, text: text,
                             time: ts > 0 ? FleetRoomVM.fmtTs(ts) : "", mine: sender == self?.myName)
        }
        socket.onPosition = { [weak self] userId, sender, lat, lng, spd, _ in
            guard let self else { return }
            self.positions[userId] = MemberPos(lat: lat, lng: lng, spd: spd, name: sender)
        }
        socket.onJoin = { [weak self] _, sender in
            self?.addChatRow(sender: "", text: "→ \(sender) 加入了房间", time: "", mine: false, system: true)
        }
        socket.onLeave = { [weak self] _, sender in
            self?.addChatRow(sender: "", text: "← \(sender) 离开了房间", time: "", mine: false, system: true)
        }
        socket.onClosed = { [weak self] reason in
            self?.statusChip = reason
        }
        socket.onError = { [weak self] code, message in
            self?.statusChip = message.isEmpty ? "连接被拒（\(code)）" : message
            self?.connecting = false
        }
        statusChip = "连接中…"
        socket.connect(url: wsUrl, token: token, room: roomCode)
    }

    /// mine 接口在 start 前由页面拉好缓存进来，这里只取 wsUrl
    private var cachedFleet: [String: Any]?

    func prime(_ fleet: [String: Any]) { cachedFleet = fleet }

    // MARK: 成员

    var myName: String {
        members.first { $0.id == meId }?.displayName ?? ""
    }

    private func applyMembers(_ items: [[String: Any]]) {
        members = items.map {
            FleetMember(id: $0["userId"] as? Int ?? 0,
                        username: $0["username"] as? String ?? "",
                        nickname: $0["nickname"] as? String ?? "",
                        role: $0["role"] as? String ?? "member",
                        online: ($0["online"] as? Bool) == true)
        }
        connecting = false
        if statusChip == "连接中…" { statusChip = "" }
    }

    // MARK: 聊天

    private func loadChatHistory() {
        Task {
            do {
                let items = try await AccountApi.fleetChat(base: base, token: token)
                var rows: [ChatMsg] = []
                for c in items {
                    let sender = c["sender"] as? String ?? ""
                    rows.append(ChatMsg(sender: sender,
                                        text: c["text"] as? String ?? "",
                                        time: FleetRoomVM.fmtIso(c["createdAt"] as? String ?? ""),
                                        mine: sender == myName, system: false))
                }
                chat = rows
                if !rows.isEmpty { showChatTemporarily() }
            } catch {
                // 历史拉不到不阻塞房间
            }
        }
    }

    func sendChat(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        socket.sendChat(t)   // 服务端落库后广播回来（含自己），不本地插行
    }

    private func addChatRow(sender: String, text: String, time: String,
                            mine: Bool, system: Bool = false) {
        withAnimation(.easeOut(duration: 0.2)) {
            chat.append(ChatMsg(sender: sender, text: text, time: time, mine: mine, system: system))
            if chat.count > 100 { chat.removeFirst(chat.count - 100) }
        }
        if !system { showChatTemporarily() }
    }

    /// 黑色半透明浮层：有消息时显示，15 秒无消息自动淡出
    private func showChatTemporarily() {
        chatVisible = true
        chatFadeTask?.cancel()
        chatFadeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.6)) { self?.chatVisible = false }
        }
    }

    // MARK: 语音

    private func connectVoice() async {
        do {
            let vt = try await AccountApi.fleetVoiceToken(base: base, token: token)
            guard let url = vt["url"] as? String, let tk = vt["token"] as? String else {
                statusChip = "语音凭证缺失"
                return
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                voice.connect(url: url, token: tk) { [weak self] err in
                    if let err {
                        self?.statusChip = "语音不可用：\(err)"
                    }
                    cont.resume()
                }
            }
        } catch let e as AccountApi.ApiError {
            statusChip = "语音不可用：\(AccountApi.ApiError.friendly(e))"
        } catch {
            statusChip = "语音不可用：\(error.localizedDescription)"
        }
    }

    func ptt(_ on: Bool) {
        voice.setPtt(on) { _ in }
    }

    // MARK: 位置上报

    func tickLocation() {
        guard gps.shouldReport() else { return }
        socket.sendPosition(lat: gps.coordinate.latitude,
                            lng: gps.coordinate.longitude,
                            spd: gps.speedKmh)
    }

    // MARK: 行程（队长）

    func tripStart() {
        guard isOwner else { return }
        Task {
            do {
                let r = try await AccountApi.fleetTripStart(base: base, token: token)
                activeTripId = r["tripId"] as? Int ?? (r["id"] as? Int ?? 0)
                showToast("行程已开始，全队轨迹记录中")
            } catch let e as AccountApi.ApiError {
                showToast(AccountApi.ApiError.friendly(e))
            } catch {
                showToast("开始失败：\(error.localizedDescription)")
            }
        }
    }

    func tripEnd() {
        guard isOwner, activeTripId != 0 else { return }
        Task {
            do {
                let r = try await AccountApi.fleetTripEnd(base: base, token: token)
                let dist = (r["distanceM"] as? Double) ?? (r["distanceM"] as? Int).map(Double.init) ?? 0
                let dur = (r["durationS"] as? Double) ?? (r["durationS"] as? Int).map(Double.init) ?? 0
                activeTripId = 0
                let km = dist / 1000
                showToast(String(format: "行程结束：%.2f km · %d 分钟", km, Int(dur / 60)))
            } catch let e as AccountApi.ApiError {
                showToast(AccountApi.ApiError.friendly(e))
            } catch {
                showToast("结束失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 踢人（队长）

    func kick(_ member: FleetMember) {
        guard isOwner, member.id != meId else { return }
        Task {
            do {
                try await AccountApi.fleetKick(base: base, token: token, userId: member.id)
                showToast("已移出 \(member.displayName)")
            } catch let e as AccountApi.ApiError {
                showToast(AccountApi.ApiError.friendly(e))
            } catch {
                showToast("操作失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 工具

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = ""
        }
    }

    /// 语音模式切换 / 折叠面板等交互共用这个 toast
    func toastMsg(_ text: String) { showToast(text) }

    /// unix 秒 → HH:mm
    static func fmtTs(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    /// ISO 串（截 T 后 5 位）→ HH:mm
    static func fmtIso(_ iso: String) -> String {
        guard iso.count >= 16, let tIdx = iso.firstIndex(of: "T") else { return "" }
        let start = iso.index(tIdx, offsetBy: 1)
        let end = iso.index(start, offsetBy: 5, limitedBy: iso.endIndex) ?? iso.endIndex
        return String(iso[start..<end])
    }
}

// MARK: - 房间页

struct FleetRoomPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss

    let fleet: [String: Any]
    @StateObject private var vm = FleetRoomVM()
    @State private var chatInput = ""
    @State private var pttPressed = false
    @State private var micOpen = false
    @State private var panelVisible = true
    @State private var tripBarVisible = false
    @State private var kickTarget: FleetMember?

    var body: some View {
        HStack(spacing: 0) {
            if panelVisible {
                memberPanel
                    .frame(width: 262)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            roomMap
        }
        .background(settings.palette.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(vm.fleetName.isEmpty ? "车队房间" : vm.fleetName)
                        .font(.system(size: 15, weight: .semibold))
                    Text("房间码 \(vm.roomCode) · \(vm.isOwner ? "我是队长" : "成员")")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
        .confirmationDialog("移出成员", isPresented: .init(get: { kickTarget != nil },
                                                      set: { if !$0 { kickTarget = nil } }),
                            titleVisibility: .visible) {
            Button("把 \(kickTarget?.username ?? "") 移出车队", role: .destructive) {
                if let m = kickTarget { vm.kick(m) }
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear { primeAndStart() }
        .onDisappear { vm.stop() }
        .onReceive(vm.gps.$coordinate) { _ in vm.tickLocation() }
    }

    // MARK: 启动

    private func primeAndStart() {
        vm.prime(fleet)
        vm.start(base: cloud.normalizedBaseURL, token: settings.userToken, fleet: fleet)
    }

    // MARK: 左侧成员面板

    private var memberPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("成员 \(vm.members.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(settings.palette.textSecondary)
                Spacer()
                Text("在线 \(vm.members.filter { $0.online }.count)")
                    .font(.system(size: 12))
                    .foregroundColor(settings.palette.textSecondary)
                // 折叠成员栏：隐藏后地图全屏（地图左上角图标恢复）
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { panelVisible = false }
                    vm.toastMsg("已隐藏成员列表（地图全屏）")
                } label: {
                    Image(systemName: "rectangle.righthalf.inset.filled")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(settings.palette.textSecondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }

            ForEach(vm.members) { m in
                memberRow(m)
            }
            Spacer(minLength: 0)

            Button(role: .destructive) {
                vm.stop()
                dismiss()
            } label: {
                Label("退出车队", systemImage: "arrow.backward.square")
                    .font(.system(size: 14, weight: .medium))
            }
        }
        .padding(12)
        .background(settings.palette.panel)
        .overlay(HStack { Rectangle().fill(settings.palette.stroke).frame(width: 1); Spacer() })
    }

    private func memberRow(_ m: FleetMember) -> some View {
        let isMe = m.id == vm.meId
        return HStack(spacing: 10) {
            avatar(m)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if m.isOwner {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 10))
                            .foregroundColor(settings.palette.warn)
                    }
                    Text(m.displayName)
                        .font(.system(size: 14, weight: isMe ? .semibold : .regular))
                        .lineLimit(1)
                    if isMe {
                        Text("本机")
                            .font(.system(size: 10))
                            .foregroundColor(settings.palette.accent)
                    }
                }
            }
            Spacer()
            Circle()
                .fill(m.online ? settings.palette.ok : settings.palette.textSecondary.opacity(0.4))
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(settings.palette.panelAlt)
        )
        .opacity(m.online ? 1 : 0.42)     // 离线灰置
        .onTapGesture {
            if vm.isOwner && !isMe { kickTarget = m }
        }
    }

    /// 彩色圆头像 + 用户名首字（与 Android markerIcon 同色系）
    private func avatar(_ m: FleetMember) -> some View {
        let color = FleetRoomVM.memberColor(m.id)
        let ch = String((m.displayName.isEmpty ? "队" : String(m.displayName.prefix(1))))
        return ZStack {
            Circle().fill(color)
            Text(ch)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: 26, height: 26)
    }

    // MARK: 右侧地图 + 浮层

    private var roomMap: some View {
        GeometryReader { geo in
            ZStack {
                FleetMapView(positions: vm.positions,
                             members: vm.members,
                             meId: vm.meId,
                             myCoordinate: vm.gps.hasFix ? vm.gps.coordinate : nil)
                    .ignoresSafeArea()

                if !vm.gps.hasFix {
                    VStack(spacing: 6) {
                        Image(systemName: "location.slash")
                            .font(.system(size: 22))
                        Text("等待定位…")
                            .font(.system(size: 13))
                    }
                    .foregroundColor(.white.opacity(0.75))
                }

                // 聊天浮层：黑色半透明集中显示，15 秒自动淡出
                if vm.chatVisible {
                    VStack {
                        Spacer()
                        HStack {
                            chatOverlay
                                .frame(maxWidth: geo.size.width * 0.55, alignment: .leading)
                            Spacer()
                        }
                        .padding(.leading, 12)
                        .padding(.bottom, 118)
                    }
                    .transition(.opacity)
                }

                // 顶部状态 chips
                VStack {
                    HStack(spacing: 8) {
                        // 成员栏隐藏后的恢复入口（面板隐藏时才出现）
                        if !panelVisible {
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) { panelVisible = true }
                                vm.toastMsg("已显示成员列表")
                            } label: {
                                chip(text: "成员", icon: "rectangle.lefthalf.inset.filled")
                            }
                            .buttonStyle(.plain)
                        }
                        chip(text: vm.roomCode.isEmpty ? "—"
                             : (vm.members.filter { $0.online }.count > 0
                                ? "在线 · \(vm.roomCode)" : vm.roomCode),
                             icon: "antenna.radiowaves.left.and.right")
                        chip(text: voiceChipText, icon: "mic.fill")
                        if !vm.statusChip.isEmpty {
                            chip(text: vm.statusChip, icon: "exclamationmark.triangle")
                        }
                        Spacer()
                        // 行程小图标：点按展开/收起行程条（进行中亮红）
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { tripBarVisible.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                if vm.activeTripId != 0 {
                                    Circle().fill(settings.palette.danger).frame(width: 8, height: 8)
                                }
                                Image(systemName: "figure.outdoor.cycle").font(.system(size: 10, weight: .semibold))
                                Text("行程").font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(vm.activeTripId != 0 ? settings.palette.danger : .white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    Spacer()
                }

                // 底部：聊天输入 + PTT + 行程条
                VStack(spacing: 8) {
                    Spacer()
                    if !vm.toast.isEmpty {
                        Text(vm.toast)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.black.opacity(0.72)))
                    }
                    HStack(spacing: 10) {
                        chatInputBar
                        pttButton
                    }
                    if tripBarVisible {
                        tripBar
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                }
            }
        }
    }

    private var voiceChipText: String {
        if vm.voice.ready { return "语音就绪" }
        if vm.statusChip.hasPrefix("语音") { return "语音异常" }
        return "语音连接中…"
    }

    private func chip(text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    // MARK: 聊天浮层

    private var chatOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(vm.chat.suffix(4))) { msg in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if !msg.sender.isEmpty {
                        Text(msg.sender)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(msg.mine ? settings.palette.ok : settings.palette.accent)
                    }
                    Text(msg.system ? msg.text : "\(msg.text) \(msg.time)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(msg.system ? 0.65 : 0.92))
                        .strikethrough(false)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
    }

    // MARK: 聊天输入

    private var chatInputBar: some View {
        HStack(spacing: 8) {
            TextField("发消息到车队…", text: $chatInput)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(sendChatInput)
            Button(action: sendChatInput) {
                Text("发送")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(settings.palette.accent))
            }
            .buttonStyle(.plain)
            .disabled(chatInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .padding(.leading, 12)
    }

    private func sendChatInput() {
        let t = chatInput
        chatInput = ""
        vm.sendChat(t)
    }

    // MARK: PTT 按钮（上方胶囊切换 按住说话 / 自由麦）

    private var pttButton: some View {
        VStack(spacing: 8) {
            // 模式胶囊：自由麦开启时青色高亮；选择持久化（AppSettings.voiceFreeMic）
            Button {
                let to = !settings.voiceFreeMic
                settings.voiceFreeMic = to
                if !to && micOpen {          // 切回按住说话前先关麦
                    micOpen = false
                    vm.ptt(false)
                }
                vm.toastMsg(to ? "自由麦：点麦克风开/关麦" : "按住说话：按住开麦，松开关麦")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: settings.voiceFreeMic ? "mic.badge.fill" : "mic.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(settings.voiceFreeMic ? "自由麦" : "按住说话")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(settings.voiceFreeMic ? settings.palette.accent : .white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.55)))
            }
            .buttonStyle(.plain)

            ZStack {
                Circle()
                    .fill(micColor.opacity(0.85))
                    .frame(width: 72, height: 72)
                Image(systemName: "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor((pttPressed || micOpen) ? .white : settings.palette.accent)
            }
            .overlay(Circle().stroke(micColor, lineWidth: 1.5))
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pttPressed else { return }
                        pttPressed = true
                        if settings.voiceFreeMic {
                            micOpen.toggle()          // 自由麦：点一下开麦/关麦
                            vm.ptt(micOpen)
                        } else {
                            micOpen = true            // PTT：按住开麦
                            vm.ptt(true)
                        }
                    }
                    .onEnded { _ in
                        pttPressed = false
                        if !settings.voiceFreeMic {
                            micOpen = false           // PTT：松开关麦
                            vm.ptt(false)
                        }
                    }
            )
            .overlay(alignment: .bottom) {
                Text(pttHint)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.8))
                    .offset(y: 18)
            }
            .padding(.trailing, 12)
            .padding(.bottom, 8)
        }
    }

    /// 麦克风状态色：PTT 按住 / 自由麦开 = 红，平时黑底
    private var micColor: Color {
        if settings.voiceFreeMic {
            return micOpen ? settings.palette.ok : Color.black.opacity(0.55)
        }
        return pttPressed ? settings.palette.danger.opacity(0.85) : Color.black.opacity(0.55)
    }

    private var pttHint: String {
        if settings.voiceFreeMic { return micOpen ? "自由麦 · 已开" : "自由麦 · 点击开麦" }
        return "按住说话"
    }

    // MARK: 行程条

    private var tripBar: some View {
        HStack {
            Circle()
                .fill(vm.activeTripId != 0 ? settings.palette.danger : settings.palette.textSecondary.opacity(0.5))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(vm.activeTripId != 0 ? "行程记录中" : "未开始行程")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(vm.isOwner ? "队长可开始 / 结束行程并记录全队轨迹" : "队长开始行程后记录全队轨迹")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
            }
            Spacer()
            if vm.isOwner {
                if vm.activeTripId != 0 {
                    Button(action: vm.tripEnd) {
                        Text("结束行程")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(settings.palette.danger))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: vm.tripStart) {
                        Text("开始行程")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(settings.palette.accent))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
    }
}

// MARK: - 成员配色

extension FleetRoomVM {
    /// 固定 8 色板，按 userId 取色（与 Android markerIcon 同思路）
    static func memberColor(_ userId: Int) -> Color {
        let colors: [UInt32] = [0x35D6E8, 0x35D07F, 0xFFB020, 0xFF7A45,
                                0x9F8CFF, 0xF75E8E, 0x6FA8FF, 0xE8D44D]
        return Color(hex: colors[abs(userId) % colors.count])
    }
}

// MARK: - 地图（MapKit，与 MapPanel.TrackMap 同层风格）

struct FleetMapView: UIViewRepresentable {
    var positions: [Int: MemberPos]
    var members: [FleetMember]
    var meId: Int
    var myCoordinate: CLLocationCoordinate2D?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let m = MKMapView(frame: .zero)
        m.isRotateEnabled = false
        m.isPitchEnabled = false
        m.showsCompass = false
        m.showsScale = false
        m.showsUserLocation = false
        m.mapType = .mutedStandard
        m.pointOfInterestFilter = .excludingAll
        m.delegate = context.coordinator
        m.overrideUserInterfaceStyle = .dark
        return m
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        // 我的位置（WS 回声之外，本机 GPS 直接兜底显示）
        var pos = positions
        if let me = myCoordinate, me.latitude != 0 || me.longitude != 0 {
            let name = members.first { $0.id == meId }?.displayName ?? "本机"
            pos[meId] = MemberPos(lat: me.latitude, lng: me.longitude, spd: nil, name: name)
        }

        // 数量或指纹变化时重建标注（位置变化只挪坐标，不重建）
        let fingerprint = pos.map { "\($0.key):\(String(format: "%.5f,%.5f", $0.value.lat, $0.value.lng))" }
            .sorted().joined(separator: "|")
        if fingerprint != c.lastFingerprint {
            let firstFit = c.lastFingerprint.isEmpty
            c.lastFingerprint = fingerprint
            map.removeAnnotations(map.annotations.filter { $0 is FleetAnnotation })
            for (userId, p) in pos {
                let a = FleetAnnotation()
                a.coordinate = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng)
                a.userId = userId
                a.displayName = p.name + (userId == meId ? "（本机）" : "")
                a.colorIdx = userId
                map.addAnnotation(a)
            }
            // 首次有标注时全览
            if firstFit && !pos.isEmpty {
                let coords = pos.values.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
                if coords.count == 1 {
                    let r = MKCoordinateRegion(center: coords[0], latitudinalMeters: 1200, longitudinalMeters: 1200)
                    map.setRegion(r, animated: false)
                } else {
                    let rect = MKPolyline(coordinates: coords, count: coords.count).boundingMapRect
                    map.setVisibleMapRect(rect,
                                          edgePadding: UIEdgeInsets(top: 80, left: 60, bottom: 140, right: 60),
                                          animated: false)
                }
            }
        } else {
            for (userId, p) in pos {
                if let a = map.annotations.first(where: { ($0 as? FleetAnnotation)?.userId == userId }) as? FleetAnnotation {
                    a.coordinate = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng)
                }
            }
        }
    }

    final class FleetAnnotation: NSObject, MKAnnotation {
        dynamic var coordinate: CLLocationCoordinate2D
        var userId = 0
        var displayName = ""
        var colorIdx = 0
        override init() {
            coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
            super.init()
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastFingerprint = ""

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? FleetAnnotation else { return nil }
            let id = "fleetMember"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKAnnotationView(annotation: a, reuseIdentifier: id)
            view.annotation = a
            view.image = FleetMapView.memberPin(color: FleetRoomVM.memberColor(a.colorIdx),
                                                initial: String(a.displayName.prefix(1)))
            view.canShowCallout = false
            return view
        }
    }
}

extension FleetMapView {
    /// 彩色圆 + 首字白字贴图（对应 Android 的 markerIcon）
    private static func memberPin(color: Color, initial: String) -> UIImage {
        let side: CGFloat = 36
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let uiColor = UIColor(color)
        return renderer.image { _ in
            let c = CGPoint(x: side / 2, y: side / 2)
            let halo = UIBezierPath(arcCenter: c, radius: 16, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            uiColor.withAlphaComponent(0.25).setFill()
            halo.fill()
            let dot = UIBezierPath(arcCenter: c, radius: 12, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            uiColor.setFill()
            dot.fill()
            UIColor.white.setStroke()
            dot.lineWidth = 2
            dot.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let s = String(initial.prefix(1)) as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2), withAttributes: attrs)
        }
    }
}
