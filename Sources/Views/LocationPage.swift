import Foundation
import SwiftUI
import CoreLocation

/// Tab ③：定位信息（与 Android 版一致：左侧地图，右侧定位信息卡）
/// 这里只做「看」，目的地搜索与导航在仪表页的地图上。
struct LocationPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var location: LocationService

    @State private var distance: Double = 900

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height * 1.12
            Group {
                if wide {
                    HStack(spacing: 12) {
                        mapCard
                        infoCard
                            .frame(width: min(340, geo.size.width * 0.34))
                    }
                } else {
                    VStack(spacing: 12) {
                        mapCard
                            .frame(height: geo.size.height * 0.52)
                        ScrollView { infoCard }
                    }
                }
            }
            .padding(12)
        }
        .onAppear { CrashLogger.mark("定位页加载") }
    }

    // MARK: - 左：地图

    private var mapCard: some View {
        MapPanel(coordinate: location.coordinate,
                 heading: location.heading,
                 speedKmh: location.speedKmh,
                 hasFix: location.hasFix,
                 distance: $distance)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 右：定位信息卡

    private var infoCard: some View {
        let p = settings.palette
        let c = location.coordinate

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(p.accent)
                Text("定位信息")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(p.textPrimary)
                Spacer()
                statusPill
            }
            .padding(.bottom, 10)

            row("纬度", location.hasFix ? String(format: "%.6f", c.latitude) : "--", mono: true)
            row("经度", location.hasFix ? String(format: "%.6f", c.longitude) : "--", mono: true)
            row("海拔", location.hasFix ? String(format: "%.0f m", location.altitude) : "--", mono: true)
            row("速度", location.hasFix ? String(format: "%.1f km/h", location.speedKmh) : "--",
                color: p.accent, mono: true)
            row("行进方向", location.hasFix ? String(format: "%.0f°", location.heading) : "--",
                color: p.accent, mono: true)
            row("定位精度", location.accuracy > 0 ? String(format: "±%.0f m", location.accuracy) : "--", mono: true)
            row("更新时间", timeText, mono: true, last: true)

            Text("iOS 不向第三方 App 提供卫星数量，用定位精度替代参考。")
                .font(.system(size: 10))
                .foregroundColor(p.textSecondary)
                .padding(.top, 10)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(p.panel.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(p.stroke, lineWidth: 1)
        )
    }

    private var statusPill: some View {
        let p = settings.palette
        let (text, color): (String, Color) = {
            if !location.authorized { return ("未授权", p.warn) }
            return location.hasFix ? ("已锁定", p.ok) : ("搜索中", p.warn)
        }()
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private func row(_ label: String, _ value: String,
                     color: Color? = nil, mono: Bool = false, last: Bool = false) -> some View {
        let p = settings.palette
        return VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(p.textSecondary)
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .medium, design: mono ? .monospaced : .default))
                    .foregroundColor(color ?? p.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.vertical, 9)

            if !last {
                Rectangle()
                    .fill(p.stroke)
                    .frame(height: 1)
            }
        }
    }

    private var timeText: String {
        guard let d = location.lastUpdate else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
