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

    @State private var tab: TabKind = .dashboard
    @State private var showConnect = false
    @State private var showSettings = false
    @State private var showUpdate = false

    var body: some View {
        ZStack {
            DashboardBackground()

            VStack(spacing: 0) {
                topBar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            CrashLogger.mark("首屏出现 页签=\(tab.title)")
            tab = settings.startTab
            UIApplication.shared.isIdleTimerDisabled = true
            location.start(enabled: settings.locationEnabled)
            if settings.autoCheckUpdate, !settings.updateManifestURL.isEmpty {
                updater.check(manifestURL: settings.updateManifestURL,
                              currentBuild: UpdateChecker.currentBuild)
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
        .sheet(isPresented: $showSettings) {
            SettingsPage()
                .environmentObject(settings)
                .environmentObject(service)
                .environmentObject(location)
                .environmentObject(updater)
        }        .alert("发现新版本", isPresented: Binding(
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

    // MARK: - 顶栏

    private var topBar: some View {
        let p = settings.palette
        return HStack(spacing: 10) {
            Text("智能车机系统")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(p.textPrimary)
                .lineLimit(1)
                .layoutPriority(0.5)

            HStack(spacing: 4) {
                ForEach(settings.visibleTabs) { t in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { tab = t }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: t.icon).font(.system(size: 11, weight: .semibold))
                            Text(t.title).font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundColor(tab == t ? p.bgDeep : p.textSecondary)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(tab == t ? p.accent : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 4)

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

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(p.textPrimary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(p.panel.opacity(0.9)))
                    .overlay(Circle().stroke(p.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(p.bg.opacity(settings.backgroundImageURL == nil ? 0.9 : 0.35))
    }

    private var statusColor: Color {
        let p = settings.palette
        if service.isDemo { return p.warn }
        switch service.state {
        case .streaming: return p.ok
        case .connected: return p.accent
        case .connecting, .scanning: return p.warn
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
