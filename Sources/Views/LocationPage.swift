import Foundation
import SwiftUI
import CoreLocation

struct LocationPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var location: LocationService

    @State private var distance: Double = 500

    var body: some View {
        let p = settings.palette

        VStack(spacing: 12) {
            MapPanel(coordinate: location.coordinate,
                     heading: location.heading,
                     speedKmh: location.speedKmh,
                     hasFix: location.hasFix,
                     distance: $distance)
                .frame(maxHeight: .infinity)

            HStack(spacing: 10) {
                tile("车速", String(format: "%.0f km/h", location.speedKmh), p.textPrimary)
                tile("航向", location.hasFix ? String(format: "%.0f°", location.heading) : "--", p.textPrimary)
                tile("海拔", location.hasFix ? String(format: "%.0f m", location.altitude) : "--", p.textPrimary)
            }

            HStack(spacing: 10) {
                tile("经度", location.hasFix ? String(format: "%.6f", location.coordinate.longitude) : "--", p.textSecondary)
                tile("纬度", location.hasFix ? String(format: "%.6f", location.coordinate.latitude) : "--", p.textSecondary)
                tile("定位", location.authorized ? (location.hasFix ? "已锁定" : "搜索中") : "未授权",
                     location.hasFix ? p.ok : p.warn)
            }
        }
        .padding(12)
    }

    private func tile(_ title: String, _ value: String, _ color: Color) -> some View {
        let p = settings.palette
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(p.textSecondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 10, radius: 12)
    }
}
