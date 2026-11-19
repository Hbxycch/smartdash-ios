import Foundation
import SwiftUI

struct DashboardPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var service: BmsService
    @EnvironmentObject var location: LocationService
    @EnvironmentObject var navi: NavigationController
    @EnvironmentObject var favorites: FavoriteStore

    @State private var mapDistance: Double = 260
    @State private var showSearch = false
    @State private var now = Date()

    var body: some View {
        GeometryReader { geo in
            // 仪表样式 2：三栏仪表（左列读数 / 中间弧形码表 / 右列控制器温度），无地图区
            if settings.gaugeStyle == 2 {
                GaugeStyle2Page()
            } else if settings.gaugeStyle == 3 {
                // 仪表样式 3：特斯拉卡片风（速度大卡 + 电池/控制器双卡 + 底部状态条），无地图区
                GaugeStyle3Page()
            } else {
                let wide = geo.size.width > geo.size.height * 1.15
                let readout = BmsReadout(snapshot: service.snapshot, settings: settings)

                Group {
                    if wide {
                        HStack(alignment: .top, spacing: 12) {
                            gaugeColumn(readout, gaugeHeight: min(geo.size.height * 0.42, 250))
                                .frame(width: geo.size.width * 0.42)
                            mapColumn
                        }
                    } else {
                        VStack(spacing: 12) {
                            gaugeColumn(readout, gaugeHeight: min(geo.size.height * 0.30, 210))
                            mapColumn
                                .frame(height: geo.size.height * 0.46)
                        }
                    }
                }
                .padding(12)
            }
        }
        .onAppear { CrashLogger.mark("仪表页加载") }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .sheet(isPresented: $showSearch) {
            NavSearchSheet(center: location.hasFix ? location.coordinate : nil) { place in
                navi.plan(to: place, from: location.coordinate, heading: location.heading)
            }
            .environmentObject(settings)
            .environmentObject(favorites)
        }
    }

    // MARK: - 左侧：表盘 + 电池 + 信息行

    private func gaugeColumn(_ readout: BmsReadout, gaugeHeight: CGFloat) -> some View {
        let p = settings.palette
        let snap = service.snapshot
        return VStack(spacing: 10) {
            // 码表左上角圆形电量：一眼可见，不用低头看电池卡
            GaugeView(speed: location.speedKmh)
                .frame(height: gaugeHeight)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) {
                    SocRingView(soc: snap.hasData ? readout.soc : nil,
                                size: 62, palette: p)
                        .padding(.leading, 6)
                        .padding(.top, 4)
                }

            batteryCard(readout)
            infoRow
        }
    }

    private func batteryCard(_ r: BmsReadout) -> some View {
        let p = settings.palette
        let color = p.socColor(r.socLevel)
        let snap = service.snapshot

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("电量")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(p.textSecondary)
                Spacer()
                Text(snap.hasData ? snap.flowText : "无数据")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(snap.hasData ? (snap.charging ? p.ok : p.accent) : p.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(p.panelAlt))
            }

            HStack(spacing: 14) {
                // 圆形电量环：电池模块的主视觉（与电池页、仪表角标同一组件）
                SocRingView(soc: snap.hasData ? r.soc : nil, size: 68, palette: p)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(r.totalVoltage > 0 ? String(format: "%.2f", r.totalVoltage) : "--")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(p.textPrimary)
                        Text("V")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(p.textSecondary)
                        if r.socEstimated {
                            Text("SOC 估算")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(p.warn)
                                .padding(.leading, 6)
                        }
                    }
                    Text("总电压")
                        .font(.system(size: 9))
                        .foregroundColor(p.textSecondary)
                }
                Spacer()
            }

            Text(BatteryProfile.cellHint(settings.chemistry, settings.series)
                 + String(format: " · 单体 %.3f V", r.cellAvg))
                .font(.system(size: 9))
                .foregroundColor(p.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .card(padding: 10)
    }

    private var infoRow: some View {
        let p = settings.palette
        return HStack(spacing: 0) {
            infoItem(value: timeText, label: "时间", palette: p)
            Divider().frame(height: 18).overlay(p.stroke)
            infoItem(value: location.hasFix ? String(format: "%.0f°", location.heading) : "--", label: "航向", palette: p)
            Divider().frame(height: 18).overlay(p.stroke)
            infoItem(value: location.hasFix ? String(format: "%.0f", location.altitude) : "--", label: "海拔 m", palette: p)
            Divider().frame(height: 18).overlay(p.stroke)
            infoItem(value: Odometer.shared.todayText, label: "今日 km", palette: p)
            Divider().frame(height: 18).overlay(p.stroke)
            infoItem(value: Odometer.shared.totalText, label: "总计 km", palette: p)
        }
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.panel.opacity(0.7))
        )
    }

    private func infoItem(value: String, label: String, palette p: Palette) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundColor(p.textPrimary)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(p.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: now)
    }

    // MARK: - 右侧：地图 + 导航

    private var mapColumn: some View {
        VStack(spacing: 10) {
            MapPanel(coordinate: location.coordinate,
                     heading: location.heading,
                     speedKmh: location.speedKmh,
                     hasFix: location.hasFix,
                     distance: $mapDistance,
                     route: navi.route?.coordinates ?? [],
                     destination: navi.route?.destination,
                     onSearch: { showSearch = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            RouteBar(navi: navi) { showSearch = true }
        }
    }
}
