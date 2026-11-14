import Foundation
import SwiftUI
import CoreLocation

struct LocationPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var location: LocationService

    @StateObject private var navi = NavigationController()
    @StateObject private var favorites = FavoriteStore()

    @State private var distance: Double = 500
    @State private var showSearch = false

    var body: some View {
        let p = settings.palette

        VStack(spacing: 10) {
            MapPanel(coordinate: location.coordinate,
                     heading: location.heading,
                     speedKmh: location.speedKmh,
                     hasFix: location.hasFix,
                     distance: $distance,
                     route: navi.route?.coordinates ?? [],
                     destination: navi.route?.destination,
                     onSearch: { showSearch = true })
                .frame(maxHeight: .infinity)

            RouteBar(navi: navi) { showSearch = true }

            HStack(spacing: 10) {
                tile("定位",
                     location.authorized ? (location.hasFix ? "已锁定" : "搜索中") : "未授权",
                     location.hasFix ? p.ok : p.warn)
                tile("海拔", location.hasFix ? String(format: "%.0f m", location.altitude) : "--", p.textPrimary)
                tile("坐标",
                     location.hasFix
                        ? String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude)
                        : "--",
                     p.textSecondary)
            }
        }
        .padding(12)
        .sheet(isPresented: $showSearch) {
            NavSearchSheet(center: location.hasFix ? location.coordinate : nil) { place in
                navi.plan(to: place, from: location.coordinate, heading: location.heading)
            }
            .environmentObject(settings)
            .environmentObject(favorites)
        }
        .onDisappear { navi.stopNavigation() }
    }

    private func tile(_ title: String, _ value: String, _ color: Color) -> some View {
        let p = settings.palette
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(p.textSecondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 10, radius: 12)
    }
}
