import Foundation
import SwiftUI

@main
struct SmartDashApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var service = BmsService()
    @StateObject private var location = LocationService()
    @StateObject private var updater = UpdateChecker()

    init() {
        // 高德 SDK 必须在使用任何 AMap 类之前完成 Key 注册
        AMapBootstrap.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(service)
                .environmentObject(location)
                .environmentObject(updater)
                .preferredColorScheme(settings.darkTheme ? .dark : .light)
        }
    }
}
