import SwiftUI

// MARK: - 消息中心

/// 消息中心（对应 Android MessageActivity），两个页签：
///  · 公告      —— 后台「公告管理」发布的运营公告（isNew 标记未读，进入即推已读水位线）
///  · 回复通知 —— 我的反馈的官方回复（拉取即视为已读，服务端顺带清零未读数）
/// 顶栏角标 = 反馈未读回复 + 公告未读（/messages/unread），RootView 60s 轮询刷新。
struct MessageCenterPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss

    @State private var showAnn = true
    @State private var annItems: [[String: Any]] = []
    @State private var replyItems: [[String: Any]] = []
    @State private var loaded = false
    @State private var showFeedbackList = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 页签胶囊：公告 / 回复通知
                HStack(spacing: 6) {
                    tabButton("公告", on: showAnn) { showAnn = true; Task { await refresh() } }
                    tabButton("回复通知", on: !showAnn) { showAnn = false; Task { await refresh() } }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let empty = emptyText {
                            Text(empty)
                                .font(.system(size: 13))
                                .foregroundColor(settings.palette.textSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 60)
                                .padding(.horizontal, 30)
                        } else if showAnn {
                            ForEach(Array(annItems.enumerated()), id: \.offset) { idx, it in
                                annRow(it, first: idx == 0)
                            }
                        } else {
                            ForEach(Array(replyItems.enumerated()), id: \.offset) { idx, it in
                                replyRow(it, first: idx == 0)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
                .refreshable { await refresh() }
            }
            .scrollContentBackground(.hidden)
            .background(settings.palette.bg)
            .navigationTitle("消息中心")
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
            }
            .task { await refresh() }
            .sheet(isPresented: $showFeedbackList) {
                FeedbackPage()
                    .environmentObject(settings)
                    .environmentObject(cloud)
            }
        }
    }

    private var emptyText: String? {
        if !loaded { return nil }
        if !settings.isUserLoggedIn { return "请先登录并配置云端服务器" }
        if showAnn {
            return annItems.isEmpty
                ? "暂无公告\n运营公告会由管理员在后台发布并推送到这里。" : nil
        } else {
            return replyItems.isEmpty
                ? "暂无回复通知\n在「设置 → 问题反馈」提交后，研发的回复会推送到这里。" : nil
        }
    }

    private func tabButton(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundColor(on ? settings.palette.bgDeep : settings.palette.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(on ? settings.palette.accent : settings.palette.panelAlt))
                .overlay(Capsule().stroke(settings.palette.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func refresh() async {
        guard settings.isUserLoggedIn else { loaded = true; return }
        let base = cloud.normalizedBaseURL
        let token = settings.userToken
        if showAnn {
            annItems = (try? await AccountApi.announcements(base: base, token: token)) ?? []
            // 进入即推已读水位线（公告未读部分清零）
            try? await AccountApi.announcementsRead(base: base, token: token)
        } else {
            replyItems = (try? await AccountApi.feedbackMine(base: base, token: token)) ?? []
        }
        loaded = true
        await refreshMessagesBadge(settings: settings, cloud: cloud)
    }

    // MARK: - 公告行

    private func annRow(_ it: [String: Any], first: Bool) -> some View {
        let title = it["title"] as? String ?? ""
        let body = it["body"] as? String ?? ""
        let isNew = it["isNew"] as? Bool ?? false
        let ts = parseTs(it["createdAt"] as? String ?? "")

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if isNew {
                    Text("新")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(settings.palette.bgDeep)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(settings.palette.danger))
                }
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(settings.palette.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if ts > 0 {
                    Text(timeText(ts))
                        .font(.system(size: 11.5))
                        .foregroundColor(settings.palette.textSecondary)
                }
            }
            if !body.isEmpty {
                Text(body)
                    .font(.system(size: 13))
                    .foregroundColor(settings.palette.textSecondary)
                    .lineSpacing(3)
                    .padding(.top, 6)
            }
            Rectangle()
                .fill(settings.palette.stroke.opacity(0.7))
                .frame(height: 1)
                .padding(.top, 14)
        }
        .padding(.top, first ? 8 : 14)
        .padding(.bottom, 2)
    }

    // MARK: - 回复通知行

    private func replyRow(_ it: [String: Any], first: Bool) -> some View {
        let status = it["status"] as? Int ?? 0
        let dot = statusColor(status)
        let title = it["title"] as? String ?? ""
        let badge = it["statusLabel"] as? String ?? ""
        let fbNo = it["fbNo"] as? String ?? ""
        let cat = it["categoryLabel"] as? String ?? ""
        let ts = parseTs(it["createdAt"] as? String ?? "")
        let reply = it["reply"] as? String ?? ""

        return Button {
            showFeedbackList = true
        } label: {
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
        .buttonStyle(.plain)
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
