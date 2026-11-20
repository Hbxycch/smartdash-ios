import Foundation
import SwiftUI

@main
struct SmartDashApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var service = BmsService()
    @StateObject private var ctrl = ZhikeService()
    @StateObject private var location = LocationService()
    @StateObject private var updater = UpdateChecker()
    @StateObject private var navi = NavigationController()
    @StateObject private var favorites = FavoriteStore()
    @StateObject private var cloud = CloudSync()
    /// 车队房间协调器：App 级持有房间 VM，配合悬浮话筒（离开房间页不断链）
    @StateObject private var fleetRoom = FleetRoomCoordinator()

    init() {
        // 崩溃捕获要最先装，装之前挂掉就什么都留不下
        CrashLogger.install()
        // 高德 SDK 不在启动时初始化：放到第一次真正用导航/搜索时再注册 Key，
        // 这样即使 Key 或 SDK 有问题也不会拖死首屏。
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(service)
                .environmentObject(ctrl)
                .environmentObject(location)
                .environmentObject(updater)
                .environmentObject(navi)
                .environmentObject(favorites)
                .environmentObject(cloud)
                .environmentObject(fleetRoom)
                .preferredColorScheme(settings.darkTheme ? .dark : .light)
        }
    }
}
