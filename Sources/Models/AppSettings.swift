import Foundation
import SwiftUI

enum BatteryVendor: String, CaseIterable, Identifiable {
    case jikong
    case ant
    var id: String { rawValue }
    var label: String {
        switch self {
        case .jikong: return "极空 JK-BMS"
        case .ant: return "蚂蚁 ANT-BMS"
        }
    }
    var shortLabel: String {
        switch self {
        case .jikong: return "极空"
        case .ant: return "蚂蚁"
        }
    }
}

enum TabKind: String, CaseIterable, Identifiable {
    case dashboard
    case battery
    case location
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "仪表"
        case .battery: return "电池"
        case .location: return "定位"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "speedometer"
        case .battery: return "battery.75percent"
        case .location: return "location.north.line"
        }
    }
}

enum MapTheme: String, CaseIterable, Identifiable {
    case auto, day, night
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "自动"
        case .day: return "白天"
        case .night: return "夜间"
        }
    }
}

/// 控制器厂家：远驱已接入（数据参与车速/转速/温度展示），
/// 其余三家仅先预留选项，接入前显示「开发中」。
enum ControllerVendor: String, CaseIterable, Identifiable {
    case fardriver, zhike, lingbo, lande
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fardriver: return "远驱"
        case .zhike: return "智科"
        case .lingbo: return "凌博"
        case .lande: return "蓝德"
        }
    }
    var supported: Bool { self == .fardriver }
    var stateText: String { supported ? "已接入" : "开发中" }
}

/// 全部偏好设置：UserDefaults 持久化，改动立刻写盘。
/// SwiftUI 侧用 @EnvironmentObject 注入，@Published 变化直接驱动刷新。
final class AppSettings: ObservableObject {

    private let d = UserDefaults.standard

    // ── 界面主题 ──
    @Published var darkTheme: Bool { didSet { d.set(darkTheme, forKey: "ui_dark") } }
    /// 自定义背景图片文件名（存在沙盒 Documents 下），空 = 纯色底
    @Published var backgroundImageFile: String { didSet { d.set(backgroundImageFile, forKey: "bg_image") } }

    // ── 电池 ──
    @Published var vendor: BatteryVendor { didSet { d.set(vendor.rawValue, forKey: "battery_vendor") } }
    @Published var chemistry: Chemistry { didSet {
        d.set(chemistry.rawValue, forKey: "bat_chem")
        // 串数还是旧体系默认值时，跟着换新体系默认，避免误配
        if series == oldValue.defaultSeries && chemistry != oldValue {
            series = chemistry.defaultSeries
        }
    } }
    @Published var series: Int { didSet { d.set(BatteryProfile.clampSeries(series), forKey: "bat_series") } }

    // ── 页签 ──
    @Published var showDashboard: Bool { didSet { d.set(showDashboard, forKey: "tab_dashboard") } }
    @Published var showBattery: Bool { didSet { d.set(showBattery, forKey: "tab_battery") } }
    @Published var showLocation: Bool { didSet { d.set(showLocation, forKey: "tab_location") } }
    @Published var defaultTab: TabKind { didSet { d.set(defaultTab.rawValue, forKey: "tab_default") } }

    // ── 地图 ──
    @Published var mapTheme: MapTheme { didSet { d.set(mapTheme.rawValue, forKey: "map_theme") } }
    @Published var headingUp: Bool { didSet { d.set(headingUp, forKey: "map_heading_up") } }

    // ── 仪表控制：样式 1（经典）已实现，样式 2/3 预留 ──
    @Published var gaugeStyle: Int { didSet { d.set(gaugeStyle, forKey: "gauge_style") } }

    // ── 控制器厂家 ──
    @Published var controllerVendor: ControllerVendor { didSet { d.set(controllerVendor.rawValue, forKey: "ctrl_vendor") } }

    // ── 用户账号（注册/登录会话）──
    @Published var userToken: String { didSet { d.set(userToken, forKey: "user_token") } }
    @Published var userName: String { didSet { d.set(userName, forKey: "user_name") } }
    @Published var userTrialDays: Int { didSet { d.set(userTrialDays, forKey: "user_trial_days") } }
    /// 本机绑定车辆名（登录接口返回的 vehicle.model），空 = 未绑定
    @Published var boundVehicle: String { didSet { d.set(boundVehicle, forKey: "bound_vehicle") } }
    /// 车型（注册时填写，回传 model 字段用），空 = 用默认值
    @Published var deviceModelHint: String { didSet { d.set(deviceModelHint, forKey: "device_model_hint") } }

    var isUserLoggedIn: Bool { !userToken.isEmpty }

    // ── 定位 ──
    @Published var locationEnabled: Bool { didSet { d.set(locationEnabled, forKey: "gps_enabled") } }

    // ── 升级 ──
    @Published var autoCheckUpdate: Bool { didSet { d.set(autoCheckUpdate, forKey: "auto_update") } }
    @Published var updateManifestURL: String { didSet { d.set(updateManifestURL, forKey: "update_url") } }

    // ── 蓝牙日志 ──
    @Published var btLogEnabled: Bool { didSet { d.set(btLogEnabled, forKey: "bt_log_enabled") } }

    init() {
        let ud = UserDefaults.standard
        let chem = Chemistry(rawValue: ud.string(forKey: "bat_chem") ?? "") ?? .lfp
        darkTheme = ud.object(forKey: "ui_dark") as? Bool ?? true
        backgroundImageFile = ud.string(forKey: "bg_image") ?? ""
        vendor = BatteryVendor(rawValue: ud.string(forKey: "battery_vendor") ?? "") ?? .jikong
        chemistry = chem
        series = BatteryProfile.clampSeries(ud.object(forKey: "bat_series") as? Int ?? chem.defaultSeries)
        showDashboard = ud.object(forKey: "tab_dashboard") as? Bool ?? true
        showBattery = ud.object(forKey: "tab_battery") as? Bool ?? true
        showLocation = ud.object(forKey: "tab_location") as? Bool ?? true
        defaultTab = TabKind(rawValue: ud.string(forKey: "tab_default") ?? "") ?? .dashboard
        mapTheme = MapTheme(rawValue: ud.string(forKey: "map_theme") ?? "") ?? .auto
        headingUp = ud.object(forKey: "map_heading_up") as? Bool ?? true
        gaugeStyle = ud.object(forKey: "gauge_style") as? Int ?? 1
        controllerVendor = ControllerVendor(rawValue: ud.string(forKey: "ctrl_vendor") ?? "") ?? .fardriver
        userToken = ud.string(forKey: "user_token") ?? ""
        userName = ud.string(forKey: "user_name") ?? ""
        userTrialDays = ud.object(forKey: "user_trial_days") as? Int ?? 0
        boundVehicle = ud.string(forKey: "bound_vehicle") ?? ""
        deviceModelHint = ud.string(forKey: "device_model_hint") ?? ""
        locationEnabled = ud.object(forKey: "gps_enabled") as? Bool ?? true
        autoCheckUpdate = ud.object(forKey: "auto_update") as? Bool ?? true
        // 升级清单出厂预填：清空后回落默认，保证「启动时检查更新」开箱可用
        let savedURL = ud.string(forKey: "update_url") ?? ""
        updateManifestURL = savedURL.trimmingCharacters(in: .whitespaces).isEmpty
            ? CloudSync.Defaults.manifest : savedURL
        btLogEnabled = ud.object(forKey: "bt_log_enabled") as? Bool ?? true
    }

    // ── 派生值 ──

    var visibleTabs: [TabKind] {
        var list: [TabKind] = []
        if showDashboard { list.append(.dashboard) }
        if showBattery { list.append(.battery) }
        if showLocation { list.append(.location) }
        if list.isEmpty { list.append(.battery) }   // 至少保留一个
        return list
    }

    var startTab: TabKind {
        visibleTabs.contains(defaultTab) ? defaultTab : (visibleTabs.first ?? .battery)
    }

    var mapNight: Bool {
        switch mapTheme {
        case .night: return true
        case .day: return false
        case .auto:
            let h = Calendar.current.component(.hour, from: Date())
            return h < 6 || h >= 18
        }
    }

    var palette: Palette { Palette(dark: darkTheme) }

    // ── 背景图存取 ──

    var backgroundImageURL: URL? {
        guard !backgroundImageFile.isEmpty else { return nil }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(backgroundImageFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 保存用户选的背景图（文件已落到 Documents），返回是否成功
    func adoptBackgroundImage(from tempURL: URL) -> Bool {
        let dst = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dashboard_bg.jpg")
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(at: tempURL, to: dst)
            backgroundImageFile = dst.lastPathComponent
            return true
        } catch {
            return false
        }
    }

    func clearBackgroundImage() {
        if let url = backgroundImageURL { try? FileManager.default.removeItem(at: url) }
        backgroundImageFile = ""
    }
}
