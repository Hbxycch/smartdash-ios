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
            let wide = geo.size.width > geo.size.height * 1.15
            let readout = BmsReadout(snapshot: service.snapshot, settings: settings)

            Group {
                if wide {
                    HStack(alignment: .top, spacing: 12) {
                        gaugeColumn(readout)
                            .frame(width: geo.size.width * 0.42)
                        mapColumn
                    }
                } else {
                    VStack(spacing: 12) {
                        gaugeColumn(readout)
                        mapColumn
                            .frame(height: geo.size.height * 0.46)
                    }
                }
            }
            .padding(12)
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

    private func gaugeColumn(_ readout: BmsReadout) -> some View {
        VStack(spacing: 10) {
            GaugeView(speed: location.speedKmh)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            batteryCard(readout)
            infoRow
        }
    }

    private func batteryCard(_ r: BmsReadout) -> some View {
        let p = settings.palette
        let color = p.socColor(r.socLevel)
        let snap = service.snapshot

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("电量")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(p.textSecondary)
                Spacer()
                Text(snap.hasData ? snap.flowText : "无数据")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(snap.hasData ? (snap.charging ? p.ok : p.accent) : p.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(p.panelAlt))
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(String(format: "%.0f", r.soc))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(color)
                Text("%")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(color.opacity(0.8))
                if r.socEstimated {
                    Text("估算")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(p.warn)
                        .padding(.leading, 4)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("总电压")
                        .font(.system(size: 10))
                        .foregroundColor(p.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(r.totalVoltage > 0 ? String(format: "%.2f", r.totalVoltage) : "--")
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(p.textPrimary)
                        Text("V")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(p.textSecondary)
                    }
                }
            }

            // 进度条
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.track)
                    Capsule()
                        .fill(color)
                        .frame(width: max(4, g.size.width * CGFloat(min(100, max(0, r.soc)) / 100)))
                }
            }
            .frame(height: 7)

            Text(BatteryProfile.cellHint(settings.chemistry, settings.series)
                 + String(format: " · 单体 %.3f V", r.cellAvg))
                .font(.system(size: 10))
                .foregroundColor(p.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .card(padding: 12)
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
            infoItem(value: "F -- / B --", label: "制动", palette: p)
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
