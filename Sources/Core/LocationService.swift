import Foundation
import Combine
import CoreLocation

/// 定位：速度（km/h）、航向、海拔、坐标。1Hz 驱动表盘与地图。
final class LocationService: NSObject, ObservableObject {

    @Published private(set) var speedKmh: Double = 0
    @Published private(set) var heading: Double = 0          // 0=北，顺时针
    @Published private(set) var altitude: Double = 0
    @Published private(set) var accuracy: Double = -1        // 水平精度（米），负数为无效
    @Published private(set) var coordinate = CLLocationCoordinate2D(latitude: 39.9087, longitude: 116.3975)
    @Published private(set) var hasFix = false
    @Published private(set) var authorized = false
    @Published private(set) var lastUpdate: Date?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 1
        manager.pausesLocationUpdatesAutomatically = false
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func start(enabled: Bool) {
        guard enabled else { manager.stopUpdatingLocation(); return }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    var authorizationText: String {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return "已授权"
        case .denied: return "被拒绝，请到 设置 → 隐私 → 定位服务 开启"
        case .restricted: return "受限"
        default: return "未授权"
        }
    }
}

extension LocationService: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            authorized = true
            manager.startUpdatingLocation()
        default:
            authorized = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        // 过滤缓存点
        if Date().timeIntervalSince(loc.timestamp) > 5 { return }
        coordinate = loc.coordinate
        hasFix = true
        lastUpdate = Date()
        altitude = loc.altitude
        accuracy = loc.horizontalAccuracy
        let kmh = max(0, loc.speed) * 3.6
        speedKmh = kmh.isFinite ? kmh : 0
        if loc.course >= 0 { heading = loc.course }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        // 低速时磁罗盘噪声大，只在有真实移动时采用
        if speedKmh > 3 { heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 无信号属正常，保留上一次数值
    }
}
