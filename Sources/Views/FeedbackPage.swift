import SwiftUI
import PhotosUI
import UIKit

// MARK: - 问题反馈列表

/// 我的反馈列表（对应 Android FeedbackActivity）。
/// 拉取即视为回复已读（服务端 /feedback/mine 顺带清零未读数）；
/// 状态点颜色：待受理青 / 处理中琥珀 / 已解决绿 / 已关闭灰；
/// 有回复的条目下方挂回复气泡，回复内容与后台「反馈管理」一致。
struct FeedbackPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss

    @State private var items: [[String: Any]] = []
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var showCompose = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let emptyText = emptyText {
                        Text(emptyText)
                            .font(.system(size: 13))
                            .foregroundColor(settings.palette.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else {
                        ForEach(Array(items.enumerated()), id: \.offset) { idx, it in
                            feedbackRow(it, first: idx == 0)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .scrollContentBackground(.hidden)
            .background(settings.palette.bg)
            .navigationTitle("问题反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("返回")
                                .font(.system(size: 15))
                        }
                    }
                    .foregroundColor(settings.palette.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCompose = true
                    } label: {
                        Label("新建", systemImage: "square.and.pencil")
                    }
                    .foregroundColor(settings.palette.accent)
                }
            }
            .overlay(alignment: .bottom) {
                if !settings.isUserLoggedIn {
                    hintBar("请先在「设置 → 用户账号」登录后再提交反馈")
                } else if loadFailed {
                    hintBar("加载失败，下拉重试或稍后再试")
                }
            }
            .refreshable { await refresh() }
            .task { await refresh() }
            .sheet(isPresented: $showCompose, onDismiss: { Task { await refresh() } }) {
                FeedbackComposePage()
                    .environmentObject(settings)
                    .environmentObject(cloud)
            }
        }
    }

    private var emptyText: String? {
        if !loaded { return nil }
        if !settings.isUserLoggedIn { return "请先登录并配置云端服务器" }
        if items.isEmpty { return "暂无反馈\n点右上角「新建」提交第一条反馈。" }
        return nil
    }

    private func hintBar(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(settings.palette.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(settings.palette.panel.opacity(0.95)))
            .overlay(Capsule().stroke(settings.palette.stroke, lineWidth: 1))
            .padding(.bottom, 12)
    }

    private func refresh() async {
        guard settings.isUserLoggedIn else { loaded = true; return }
        let base = cloud.normalizedBaseURL
        let token = settings.userToken
        do {
            items = try await AccountApi.feedbackMine(base: base, token: token)
            loadFailed = false
        } catch {
            loadFailed = items.isEmpty
        }
        loaded = true
        // 角标里的反馈未读部分已随本次拉取清零，全量重算
        await refreshMessagesBadge(settings: settings, cloud: cloud)
    }

    // MARK: - 单条反馈

    private func feedbackRow(_ it: [String: Any], first: Bool) -> some View {
        let status = it["status"] as? Int ?? 0
        let dot = statusColor(status)
        let title = it["title"] as? String ?? ""
        let badge = it["statusLabel"] as? String ?? ""
        let fbNo = it["fbNo"] as? String ?? ""
        let cat = it["categoryLabel"] as? String ?? ""
        let ts = parseTs(it["createdAt"] as? String ?? "")
        let reply = it["reply"] as? String ?? ""

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(dot)
                    .frame(width: 9, height: 9)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 14))
                            .foregroundColor(settings.palette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(badge)
                            .font(.system(size: 11))
                            .foregroundColor(dot)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(dot.opacity(0.14)))
                    }
                    Text(fbNo + (ts > 0 ? " · " + timeText(ts) : "") + (cat.isEmpty ? "" : " · " + cat))
                        .font(.system(size: 12))
                        .foregroundColor(settings.palette.textSecondary)

                    if !reply.isEmpty {
                        Text("回复：" + reply)
                            .font(.system(size: 12))
                            .foregroundColor(settings.palette.textSecondary)
                            .lineSpacing(3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(settings.palette.accent.opacity(0.08)))
                            .padding(.top, 8)
                    }
                }
            }
            .padding(.top, first ? 8 : 18)
            .padding(.bottom, 14)
        }
    }

    // MARK: - 工具

    private func statusColor(_ s: Int) -> Color {
        let p = settings.palette
        switch s {
        case 1: return p.warn        // 处理中
        case 2: return p.ok          // 已解决
        case 3: return p.textSecondary.opacity(0.6) // 已关闭
        default: return p.accent     // 待受理
        }
    }

    private func parseTs(_ iso: String) -> TimeInterval {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: iso)?.timeIntervalSince1970 ?? 0
    }

    private func timeText(_ ts: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

/// 角标刷新：全量拉 /messages/unread（顶栏 60s 轮询、公告已读、反馈列表已读共用口径）。
/// 网络失败保留旧值，不打扰用户。
func refreshMessagesBadge(settings: AppSettings, cloud: CloudSync) async {
    guard settings.isUserLoggedIn else {
        if settings.messagesUnread != 0 { settings.messagesUnread = 0 }
        return
    }
    let base = cloud.normalizedBaseURL
    let token = settings.userToken
    if let r = try? await AccountApi.messagesUnread(base: base, token: token) {
        let total = r["total"] as? Int ?? 0
        if settings.messagesUnread != total { settings.messagesUnread = total }
    }
}

// MARK: - 新建反馈

/// 新建反馈（对应 Android FeedbackComposeActivity）：
/// 类型胶囊（单选）+ 描述 + 截图（相册选，≤3 张，压到 ≤400KB）。
/// 设备快照自动附带：设备号 / App 版本 / 保护板·控制器厂家 / 授权状态 / 时间。
struct FeedbackComposePage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss

    private static let cats: [(key: String, label: String)] = [
        ("bug", "功能异常"), ("data", "数据不对"), ("connection", "连接问题"),
        ("suggestion", "功能建议"), ("other", "其他"),
    ]

    @State private var catIndex = 0
    @State private var content = ""
    @State private var images: [UIImage] = []
    @State private var pickerItem: PhotosPickerItem?
    @State private var busy = false
    @State private var errorText = ""
    @State private var submittedNo: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 类型胶囊（单选）
                    Text("问题类型")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(settings.palette.textSecondary)
                    HStack(spacing: 6) {
                        ForEach(Array(Self.cats.enumerated()), id: \.offset) { i, c in
                            Button {
                                catIndex = i
                            } label: {
                                Text(c.label)
                                    .font(.system(size: 12, weight: catIndex == i ? .semibold : .regular))
                                    .foregroundColor(catIndex == i ? settings.palette.bgDeep : settings.palette.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        Capsule().fill(catIndex == i
                                                       ? settings.palette.accent
                                                       : settings.palette.panelAlt))
                                    .overlay(Capsule().stroke(settings.palette.stroke, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // 描述
                    Text("问题描述")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(settings.palette.textSecondary)
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $content)
                            .font(.system(size: 14))
                            .foregroundColor(settings.palette.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(height: 120)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(settings.palette.panelAlt))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(settings.palette.stroke, lineWidth: 1))
                        if content.isEmpty {
                            Text("说说遇到了什么问题，越具体越快定位（必填）")
                                .font(.system(size: 13))
                                .foregroundColor(settings.palette.textSecondary.opacity(0.7))
                                .padding(.top, 16)
                                .padding(.leading, 14)
                                .allowsHitTesting(false)
                        }
                    }

                    // 截图：相册选，≤3 张
                    HStack {
                        Text("截图（选填，最多 3 张）")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(settings.palette.textSecondary)
                        Spacer()
                        if !images.isEmpty {
                            Button("清空") { images.removeAll() }
                                .font(.system(size: 12))
                                .foregroundColor(settings.palette.danger)
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        images.remove(at: i)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 15))
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                    }
                                    .offset(x: 5, y: -5)
                                }
                        }
                        if images.count < 3 {
                            PhotosPicker(selection: $pickerItem, matching: .images) {
                                VStack(spacing: 3) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 17, weight: .medium))
                                    Text("添加")
                                        .font(.system(size: 10))
                                }
                                .foregroundColor(settings.palette.textSecondary)
                                .frame(width: 64, height: 64)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(settings.palette.panelAlt))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(settings.palette.stroke,
                                                      style: StrokeStyle(lineWidth: 1, dash: [4])))
                            }
                        }
                    }

                    // 自动附带的设备快照说明
                    Text("提交时会自动附带设备快照：设备号 \(cloud.deviceNo) · 版本 \(UpdateChecker.currentVersion)（\(UpdateChecker.currentBuild)） · 保护板 \(settings.vendor.label) · 控制器 \(settings.controllerVendor.label) · \(authStateText)")
                        .font(.system(size: 10.5))
                        .foregroundColor(settings.palette.textSecondary.opacity(0.8))
                        .lineSpacing(3)

                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.system(size: 12))
                            .foregroundColor(settings.palette.danger)
                    }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
            .background(settings.palette.bg)
            .navigationTitle("新建反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(settings.palette.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("提交").font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .foregroundColor(settings.palette.accent)
                    .disabled(busy || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: pickerItem) { item in
                guard let item else { return }
                item.loadTransferable(type: Data.self) { result in
                    guard case .success(let data) = result, let data,
                          let img = UIImage(data: data) else { return }
                    DispatchQueue.main.async {
                        if images.count < 3 { images.append(img) }
                        pickerItem = nil
                    }
                }
            }
            .alert("提交成功", isPresented: Binding(
                get: { submittedNo != nil },
                set: { if !$0 { submittedNo = nil; dismiss() } }
            )) {
                Button("好的", role: .cancel) { }
            } message: {
                Text("反馈编号 \(submittedNo ?? "")\n研发回复后会推送到消息中心。")
            }
        }
    }

    private var authStateText: String {
        cloud.phase == .ready || !settings.deviceAuthExpires.isEmpty ? "已激活" : "未激活"
    }

    private func submit() async {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true
        errorText = ""
        defer { busy = false }

        // 截图压缩：最长边 1280，JPEG 循环降质到 ≤400KB（与 Android 同口径）
        var payloads: [[String: Any]] = []
        for (i, img) in images.enumerated() {
            if let b64 = Self.compress(img, maxKB: 400) {
                payloads.append(["mime": "image/jpeg", "data": b64, "index": i])
            }
        }

        do {
            let r = try await AccountApi.feedbackCreate(
                base: cloud.normalizedBaseURL,
                token: settings.userToken,
                category: Self.cats[catIndex].key,
                content: text,
                deviceNo: cloud.deviceNo,
                appVersion: "\(UpdateChecker.currentVersion)（\(UpdateChecker.currentBuild)）",
                bmsVendor: settings.vendor.label,
                ctrlVendor: settings.controllerVendor.label,
                authState: authStateText,
                images: payloads.isEmpty ? nil : payloads)
            submittedNo = r["fbNo"] as? String ?? ""
        } catch let e as AccountApi.ApiError {
            errorText = AccountApi.ApiError.friendly(e)
        } catch {
            errorText = "提交失败，请检查网络后重试"
        }
    }

    /// 压到 ≤400KB 的 JPEG base64（不带 data: 前缀）
    private static func compress(_ image: UIImage, maxKB: Int) -> String? {
        var scale = 1.0
        let maxSide: CGFloat = 1280
        let w = image.size.width, h = image.size.height
        let longest = max(w, h)
        if longest > maxSide { scale = maxSide / longest }
        let target = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }

        var quality: CGFloat = 0.75
        var data = resized.jpegData(compressionQuality: quality)
        while let d = data, d.count > maxKB * 1024, quality > 0.25 {
            quality -= 0.12
            data = resized.jpegData(compressionQuality: quality)
        }
        guard let final = data, final.count <= maxKB * 1024 else { return nil }
        return final.base64EncodedString()
    }
}
