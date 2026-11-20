import Foundation
import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var service: BmsService
    @EnvironmentObject var location: LocationService
    @EnvironmentObject var updater: UpdateChecker
    @EnvironmentObject var navi: NavigationController
    @EnvironmentObject var favorites: FavoriteStore
    @EnvironmentObject var cloud: CloudSync
    @EnvironmentObject var ctrl: ZhikeService
    @EnvironmentObject var fleetRoom: FleetRoomCoordinator

    @State private var tab: TabKind = .dashboard
    @State private var showConnect = false
    @State private var showSettings = false
    @State private var showUpdate = false
    @State private var showCtrlScan = false
    @State private var showMessages = false
    @State private var showAccount = false
    @State private var showFleet = false

    var body: some View {
        ZStack {
            DashboardBackground()

            HStack(spacing: 0) {
                sideDock
                VStack(spacing: 0) {
                    topBar
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // 悬浮话筒（对齐 Android v5.46）：房间在后台运行时挂在主界面，点击直达房间页
            if fleetRoom.inRoom {
                FleetMicFloat {
                    fleetRoom.wantsRoomJump = true
                    showFleet = true
                }
            }
        }
        .onAppear {
            CrashLogger.mark("首屏出现 页签=\(tab.title)")
            tab = settings.startTab
            // 地图「跟随系统」档：刷新系统深浅色判定（系统切换主题后最迟 60s 换底图）
            settings.refreshSystemDark()
            UIApplication.shared.isIdleTimerDisabled = true
            location.start(enabled: settings.locationEnabled)
            cloud.start(bms: service, location: location, settings: settings)
            if settings.autoCheckUpdate {
                // 地址留空时 resolvedManifestURL 静默回落内置更新源
                updater.check(manifestURL: settings.resolvedManifestURL,
                              currentBuild: UpdateChecker.currentBuild)
            }
            // 控制器链路：错开 BMS 的连接高峰，稍晚一点用上次的 identifier 直连（受自动连接开关控制）
            if settings.controllerVendor == .zhike {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    if settings.ctrlAutoConnect { self.ctrl.autoConnectIfSaved() }
                }
            }
            // 消息角标：进场先刷一次，之后 60s 轮询（反馈未读回复 + 公告未读）
            Task { await refreshMessagesBadge(settings: settings, cloud: cloud) }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            settings.refreshSystemDark()
            Task { await refreshMessagesBadge(settings: settings, cloud: cloud) }
        }
        .onChange(of: settings.controllerVendor) { v in
            if v == .zhike {
                if settings.ctrlAutoConnect { ctrl.autoConnectIfSaved() }
            } else {
                ctrl.disconnect()
            }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: settings.visibleTabs) { tabs in
            if !tabs.contains(tab) { tab = tabs.first ?? .battery }
        }
        .onChange(of: tab) { newTab in
            CrashLogger.mark("切换到页签 \(newTab.title)")
        }
        .sheet(isPresented: $showConnect) {
            ConnectSheet()
                .environmentObject(settings)
                .environmentObject(service)
        }
        .fullScreenCover(isPresented: $showCtrlScan) {
            ControllerScanView()
                .environmentObject(settings)
                .environmentObject(ctrl)
        }
        .sheet(isPresented: $showSettings) {
            SettingsPage()
                .environmentObject(settings)
                .environmentObject(service)
                .environmentObject(location)
                .environmentObject(updater)
                .environmentObject(cloud)
        }
        .fullScreenCover(isPresented: $showAccount) {
            NavigationStack {
                AccountPage()
                    .environmentObject(settings)
                    .environmentObject(cloud)
            }
        }
        .fullScreenCover(isPresented: $showFleet) {
            NavigationStack {
                FleetPage()
                    .environmentObject(settings)
                    .environmentObject(cloud)
                    .environmentObject(fleetRoom)
            }
        }
        .sheet(isPresented: $showMessages) {
            MessageCenterPage()
                .environmentObject(settings)
                .environmentObject(cloud)
        }
        .alert("发现新版本", isPresented: Binding(
            get: { updater.latest != nil },
            set: { if !$0 { updater.dismiss() } }
        )) {
            if let url = updater.latest?.downloadURL {
                Button("前往下载") { UIApplication.shared.open(url) }
            }
            Button("稍后", role: .cancel) { updater.dismiss() }
        } message: {
            if let info = updater.latest {
                Text("\(info.versionName)（\(info.versionCode)）\n\(info.changelog)")
            }
        }
    }

    // MARK: - 左侧玻璃 Dock

    private var sideDock: some View {
        let p = settings.palette
        return VStack(spacing: 0) {
            // 时钟置顶
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 23, weight: .bold, design: .monospaced))
                    .foregroundColor(p.textPrimary.opacity(0.95))
                    .padding(.top, 12)
            }

            // 仪表 / BMS / 定位（显隐由设置页页签开关控制，见 visibleTabs）
            ForEach(settings.visibleTabs) { kind in
                dockItem(icon: kind.icon, title: kind.title,
                         colors: Self.dockTabColors[kind] ?? [],
                         selected: tab == kind) {
                    withAnimation(.easeInOut(duration: 0.15)) { tab = kind }
                }
                .padding(.top, 16)
            }

            // 车队 / 个人中心：独立整屏页
            dockItem(icon: "person.3.fill", title: "车队",
                     colors: [Color(hex: 0xA97BFF), Color(hex: 0x7C4DE0)],
                     selected: false) { showFleet = true }
                .padding(.top, 16)

            dockItem(icon: "person.crop.circle", title: "个人中心",
                     colors: [Color(hex: 0x4DD8D2), Color(hex: 0x23A8B8)],
                     selected: false) { showAccount = true }
                .padding(.top, 16)

            Spacer(minLength: 0)

            // 设置钉在 Dock 底部（半透明玻璃块）
            Rectangle().fill(p.stroke.opacity(0.5))
                .frame(width: 32, height: 1)
                .padding(.bottom, 12)

            dockItem(icon: "gearshape.fill", title: "设置", colors: nil,
                     selected: false) { showSettings = true }
        }
        .frame(width: 100)
        .padding(.bottom, 16)
        .background(dockBackground(p))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.leading, 14)
        .padding(.vertical, 14)
    }

    /// 选中态：恢复全彩 + 白圈 + 左侧指示条；未选中整体压暗
    private func dockItem(icon: String, title: String, colors: [Color]?,
                          selected: Bool, action: @escaping () -> Void) -> some View {
        let p = settings.palette
        return Button(action: action) {
            ZStack(alignment: .leading) {
                if let colors = colors {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: colors,
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                } else {
                    // 设置：半透明玻璃块
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(p.dark ? Color.white.opacity(0.12) : Color.white.opacity(0.66))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(p.dark ? Color.white.opacity(0.16) : p.stroke, lineWidth: 1))
                }
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(p.dark ? .white : (colors == nil ? p.textSecondary : .white))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if selected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.95), lineWidth: 2.5)
                    Rectangle()
                        .fill(Color(hex: 0x4DA3FF))
                        .frame(width: 3.5, height: 24)
                        .cornerRadius(2)
                        .offset(x: -11)
                }
            }
            .frame(width: 56, height: 56)
            .opacity(selected ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// 玻璃面板：深色主题深蓝玻璃，浅色主题白色磨砂
    private func dockBackground(_ p: Palette) -> some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(p.dark
                  ? LinearGradient(colors: [Color(hex: 0x263254).opacity(0.60),
                                            Color(hex: 0x101729).opacity(0.50)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                  : LinearGradient(colors: [Color.white.opacity(0.82),
                                            Color.white.opacity(0.62)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(p.dark ? Color.white.opacity(0.10) : Color.white.opacity(0.85),
                        lineWidth: 1))
            .shadow(color: .black.opacity(p.dark ? 0.45 : 0.12), radius: 14, y: 6)
    }

    private static let dockTabColors: [TabKind: [Color]] = [
        .dashboard: [Color(hex: 0x4DA3FF), Color(hex: 0x2C6FD6)],
        .battery: [Color(hex: 0x61D98B), Color(hex: 0x2FB968)],
        .location: [Color(hex: 0xFF9F4D), Color(hex: 0xE2701F)],
    ]

    // MARK: - 顶栏

    private var topBar: some View {
        let p = settings.palette
        return HStack(spacing: 10) {
            Text("智能仪表")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(p.textPrimary)
                .lineLimit(1)
                .layoutPriority(0.5)

            Spacer(minLength: 4)

            // 控制器连接胶囊：智科已接入 → 点击进整屏扫描页选设备；
            // 其余厂家未接入 → 点击去设置里改厂家
            Button {
                if settings.controllerVendor == .zhike {
                    showCtrlScan = true
                } else {
                    showSettings = true
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(ctrlDotColor)
                        .frame(width: 7, height: 7)
                    Text(ctrlPillText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ctrlPillColor)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(p.panel.opacity(0.9)))
                .overlay(Capsule().stroke(p.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                showConnect = true
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(service.sourceLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(p.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(p.panel.opacity(0.9)))
                .overlay(Capsule().stroke(p.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)

            // 消息铃铛：反馈未读回复 + 公告未读（后台公告管理 / 反馈回复推送）
            Button {
                showMessages = true
            } label: {
                Image(systemName: settings.messagesUnread > 0 ? "bell.badge" : "bell")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(p.textPrimary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(p.panel.opacity(0.9)))
                    .overlay(Circle().stroke(p.stroke, lineWidth: 1))
                    .overlay(alignment: .topTrailing) {
                        if settings.messagesUnread > 0 {
                            Text(settings.messagesUnread > 99 ? "99+" : "\(settings.messagesUnread)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(p.danger))
                                .offset(x: 5, y: -4)
                        }
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(p.bg.opacity(settings.backgroundImageURL == nil ? 0.9 : 0.35))
    }

    private var ctrlPillText: String {
        let v = settings.controllerVendor
        if v == .zhike { return ctrl.pillText }
        return v.supported ? "控制器未连接" : "\(v.label)控制器未接入"
    }

    private var ctrlDotColor: Color {
        let p = settings.palette
        guard settings.controllerVendor == .zhike else { return p.textSecondary.opacity(0.55) }
        if ctrl.pillColorIsActive { return p.ok }
        if ctrl.pillNeedsWarn { return p.warn }
        return p.textSecondary.opacity(0.55)
    }

    private var ctrlPillColor: Color {
        let p = settings.palette
        guard settings.controllerVendor == .zhike else { return p.textSecondary }
        if ctrl.pillColorIsActive { return p.textPrimary }
        if ctrl.pillNeedsWarn { return p.warn }
        return p.textSecondary
    }

    private var statusColor: Color {
        let p = settings.palette
        if service.isDemo { return p.warn }
        switch service.state {
        case .streaming: return p.ok
        case .connected: return p.accent
        case .connecting, .scanning, .reconnecting: return p.warn
        case .failed: return p.danger
        case .idle: return p.textSecondary
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .dashboard:
            DashboardPage()
        case .battery:
            BatteryPage()
        case .location:
            LocationPage()
        }
    }
}
