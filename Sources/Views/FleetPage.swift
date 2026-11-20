import Foundation
import SwiftUI

/// 车队页：创建 / 加入（6 位房间码）/ 当前车队卡片（与 Android FleetActivity 同口径）。
/// 「进入房间」跳 FleetRoomPage：左侧成员、右侧地图 + 聊天浮层 + PTT + 行程条。
struct FleetPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var cloud: CloudSync
    @EnvironmentObject var coordinator: FleetRoomCoordinator

    @State private var fleet: [String: Any]?
    @State private var newName = ""
    @State private var roomCode = ""
    @State private var busy = false
    @State private var message = ""
    @State private var messageIsError = false
    @State private var showLeaveConfirm = false
    @State private var showEndConfirm = false
    /// 悬浮话筒「直达房间」的编程式推入
    @State private var pushRoom = false

    var body: some View {
        Form {
            if let f = fleet {
                currentSection(f)
            } else {
                createSection
                joinSection
            }
            hintSection
        }
        .navigationTitle("车队")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $pushRoom) {
            if let f = fleet {
                FleetRoomPage(fleet: f, vm: coordinator.roomVM(f))
            }
        }
        .onAppear {
            // 悬浮话筒请求直达房间：车队卡片已在就立即推入，否则等 refresh 拉到后再推
            if coordinator.wantsRoomJump, fleet != nil {
                coordinator.wantsRoomJump = false
                pushRoom = true
            }
            refresh()
        }
        .alert("退出车队", isPresented: $showLeaveConfirm) {
            Button("退出", role: .destructive) { leave() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后如需再次同行，输入房间码重新加入即可。")
        }
        .alert("结束车队", isPresented: $showEndConfirm) {
            Button("结束车队", role: .destructive) { endFleet() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("结束车队会解散所有成员，聊天与行程记录保留。确认结束？")
        }
    }

    // MARK: 当前车队

    private var isOwner: Bool {
        (fleet?["myRole"] as? String) == "owner"
    }

    private func currentSection(_ f: [String: Any]) -> some View {
        Section {
            HStack {
                Text("车队名")
                Spacer()
                Text(f["name"] as? String ?? "--").foregroundColor(.secondary)
            }
            HStack {
                Text("房间码")
                Spacer()
                Text(f["roomCode"] as? String ?? "--")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundColor(.accentColor)
            }
            HStack {
                Text("我的角色")
                Spacer()
                Text(isOwner ? "队长" : "成员").foregroundColor(.secondary)
            }
            let members = f["members"] as? [[String: Any]] ?? []
            HStack {
                Text("成员")
                Spacer()
                Text("\(members.count) 人 · 在线 \(members.filter { ($0["online"] as? Bool) == true }.count)")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            let unread = (f["chatUnread"] as? Int) ?? 0
            HStack {
                Text("未读消息")
                Spacer()
                Text(unread > 0 ? "\(unread) 条" : "无")
                    .foregroundColor(unread > 0 ? .orange : .secondary)
                    .monospacedDigit()
            }

            NavigationLink {
                FleetRoomPage(fleet: f, vm: coordinator.roomVM(f))
            } label: {
                Label("进入房间", systemImage: "dot.radiowaves.left.and.right")
                    .fontWeight(.semibold)
            }

            Button(role: .destructive) {
                if isOwner { showEndConfirm = true } else { showLeaveConfirm = true }
            } label: {
                Label(isOwner ? "结束车队（解散全员）" : "退出车队",
                      systemImage: isOwner ? "xmark.octagon" : "tray.and.arrow.down")
            }
        } footer: {
            Text(isOwner
                 ? "把房间码告诉队友即可组队；结束车队前可随时在房间内开始/结束行程。"
                 : "在房间内可以按住 PTT 对讲、看队友实时位置、给全队发消息。")
        }
    }

    // MARK: 创建

    private var createSection: some View {
        Section("创建车队") {
            TextField("车队名（如 周末摩旅）", text: $newName)
            Button {
                create()
            } label: {
                HStack {
                    Spacer()
                    if busy { ProgressView().padding(.trailing, 6) }
                    Text("创建车队").fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(busy || newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: 加入

    private var joinSection: some View {
        Section("加入车队") {
            TextField("6 位房间码", text: $roomCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
            Button {
                join()
            } label: {
                HStack {
                    Spacer()
                    Text("加入车队").fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(busy || roomCode.count < 6)
        }
    }

    private var hintSection: some View {
        Section {
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(messageIsError ? .red : .secondary)
            }
            Text("车队支持实时语音对讲（按住说话）、成员位置共享、车队聊天与行程轨迹记录；所有数据基于本次车队房间。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    // MARK: 动作

    private func showMsg(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }

    private func refresh() {
        let base = cloud.normalizedBaseURL
        guard !base.isEmpty, settings.isUserLoggedIn else { return }
        Task {
            do {
                let r = try await AccountApi.fleetMine(base: base, token: settings.userToken)
                await MainActor.run {
                    fleet = r["fleet"] as? [String: Any]
                    // 悬浮话筒直达：拉到车队后立即推入房间页
                    if coordinator.wantsRoomJump, fleet != nil {
                        coordinator.wantsRoomJump = false
                        pushRoom = true
                    }
                }
            } catch {
                // 拉不到沿用当前显示
            }
        }
    }

    private func create() {
        let base = cloud.normalizedBaseURL
        guard !base.isEmpty else {
            showMsg("请先到「设置 → 云同步」填写服务器地址", isError: true)
            return
        }
        busy = true
        Task {
            do {
                _ = try await AccountApi.fleetCreate(base: base, token: settings.userToken,
                                                     name: newName.trimmingCharacters(in: .whitespaces))
                let r = try await AccountApi.fleetMine(base: base, token: settings.userToken)
                await MainActor.run {
                    busy = false
                    fleet = r["fleet"] as? [String: Any]
                    newName = ""
                    showMsg("车队创建成功，把房间码告诉队友吧", isError: false)
                }
            } catch let e as AccountApi.ApiError {
                await MainActor.run {
                    busy = false
                    showMsg(AccountApi.ApiError.friendly(e), isError: true)
                }
            } catch {
                await MainActor.run {
                    busy = false
                    showMsg("无法连接服务器：\(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private func join() {
        let base = cloud.normalizedBaseURL
        guard !base.isEmpty else {
            showMsg("请先到「设置 → 云同步」填写服务器地址", isError: true)
            return
        }
        let code = roomCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 6 else {
            showMsg("房间码是 6 位字母数字", isError: true)
            return
        }
        busy = true
        Task {
            do {
                _ = try await AccountApi.fleetJoin(base: base, token: settings.userToken, roomCode: code)
                let r = try await AccountApi.fleetMine(base: base, token: settings.userToken)
                await MainActor.run {
                    busy = false
                    fleet = r["fleet"] as? [String: Any]
                    roomCode = ""
                    showMsg("已加入车队", isError: false)
                }
            } catch let e as AccountApi.ApiError {
                await MainActor.run {
                    busy = false
                    showMsg(AccountApi.ApiError.friendly(e), isError: true)
                }
            } catch {
                await MainActor.run {
                    busy = false
                    showMsg("无法连接服务器：\(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private func leave() {
        let base = cloud.normalizedBaseURL
        guard !base.isEmpty else { return }
        Task {
            do {
                _ = try await AccountApi.fleetLeave(base: base, token: settings.userToken)
                await MainActor.run {
                    coordinator.closeRoom()   // 悬浮话筒随之消失
                    fleet = nil
                }
            } catch let e as AccountApi.ApiError {
                await MainActor.run { showMsg(AccountApi.ApiError.friendly(e), isError: true) }
            } catch {}
        }
    }

    private func endFleet() {
        let base = cloud.normalizedBaseURL
        guard !base.isEmpty else { return }
        Task {
            do {
                _ = try await AccountApi.fleetEnd(base: base, token: settings.userToken)
                await MainActor.run {
                    coordinator.closeRoom()   // 悬浮话筒随之消失
                    fleet = nil
                }
            } catch let e as AccountApi.ApiError {
                await MainActor.run { showMsg(AccountApi.ApiError.friendly(e), isError: true) }
            } catch {}
        }
    }
}
