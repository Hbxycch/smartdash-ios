import Foundation
import SwiftUI

@main
struct JKBmsMonitorApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var service = BmsService()
    @StateObject private var location = LocationService()
    @StateObject private var updater = UpdateChecker()

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
