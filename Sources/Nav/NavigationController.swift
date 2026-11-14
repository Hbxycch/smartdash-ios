import Foundation
import CoreLocation
import Combine

/// 摩托车算路需要的车辆信息（摩托车是收费接口，必须带车牌与排量）。
/// 正式上线前在设置里做成可填；先给一份保守默认值。
enum MotorcycleProfile {
    static var plate: String {
        get { UserDefaults.standard.string(forKey: "moto_plate") ?? "京B00000" }
        set { UserDefaults.standard.set(newValue, forKey: "moto_plate") }
    }
    static var displacement: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "moto_cc")
            return v > 0 ? v : 150
        }
        set { UserDefaults.standard.set(newValue, forKey: "moto_cc") }
    }
}

/// 导航总控：对界面只暴露「算路结果 + 当前引导」，
/// 底下按车型分派给高德的驾车 / 骑行两个管理器。
final class NavigationController: NSObject, ObservableObject {

    @Published var mode: TravelMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "nav_mode") }
    }

    @Published private(set) var route: RouteSummary?
    @Published private(set) var planning = false
    @Published private(set) var planError: String?
    @Published private(set) var notice: String?          // 降级提示之类，非错误
    @Published private(set) var navigating = false
    @Published private(set) var guidanceRoad: String = ""
    @Published private(set) var remainDistance: Int = 0
    @Published private(set) var remainTime: Int = 0

    private let drive = DriveAgent()
    private let ride = RideAgent()

    private var lastStart: CLLocationCoordinate2D?
    private var lastHeading: Double = 0
    private var lastDestination: Place?

    override init() {
        mode = TravelMode(rawValue: UserDefaults.standard.string(forKey: "nav_mode") ?? "") ?? .ebike
        super.init()

        drive.onRoute = { [weak self] summary in self?.handleRoute(summary) }
        drive.onFailure = { [weak self] msg in self?.handleFailure(msg) }
        drive.onNotice = { [weak self] msg in self?.notice = msg }
        drive.onInfo = { [weak self] info in self?.handleInfo(info) }

        ride.onRoute = { [weak self] summary in self?.handleRoute(summary) }
        ride.onFailure = { [weak self] msg in self?.handleFailure(msg) }
        ride.onInfo = { [weak self] info in self?.handleInfo(info) }
    }

    // MARK: - 对外

    func plan(to place: Place, from coordinate: CLLocationCoordinate2D, heading: Double = 0) {
        guard AMapBootstrap.configured else {
            planError = "未配置高德 Key，无法算路"
            return
        }
        lastStart = coordinate
        lastHeading = heading
        lastDestination = place

        planning = true
        planError = nil
        notice = nil
        route = nil
        navigating = false

        switch mode {
        case .ebike:
            ride.plan(from: coordinate, to: place)
        case .car, .motorcycle:
            drive.plan(from: coordinate, to: place, heading: heading, motorcycle: mode == .motorcycle)
        }
    }

    /// 换车型后按同一目的地重算，避免用户再搜一次
    func replan(for newMode: TravelMode) {
        mode = newMode
        guard let dest = lastDestination, let start = lastStart else { return }
        plan(to: dest, from: start, heading: lastHeading)
    }

    func startNavigation() {
        guard route != nil else { return }
        navigating = true
        if mode == .ebike {
            ride.start()
        } else {
            drive.start()
        }
    }

    func stopNavigation() {
        navigating = false
        guidanceRoad = ""
        remainDistance = 0
        remainTime = 0
        drive.stop()
        ride.stop()
        route = nil
    }

    // MARK: - 内部

    private func handleRoute(_ summary: RouteSummary?) {
        planning = false
        guard var s = summary else {
            planError = "没有算出可用路线"
            return
        }
        s.mode = mode
        route = s
        remainDistance = s.distance
        remainTime = s.duration
    }

    private func handleFailure(_ message: String) {
        planning = false
        planError = message
    }

    private func handleInfo(_ info: AMapNaviInfo?) {
        guard let info = info else { return }
        let road = info.nextRoadName ?? info.currentRoadName ?? ""
        guidanceRoad = road
        remainDistance = info.routeRemainDistance
        remainTime = info.routeRemainTime
    }
}

// MARK: - 驾车 / 摩托车

/// 汽车与摩托车都走 AMapNaviDriveManager，靠 AMapNaviVehicleInfo.type = 11 切成摩托车路网。
final class DriveAgent: NSObject, AMapNaviDriveManagerDelegate, AMapNaviDriveDataRepresentable {

    var onRoute: ((RouteSummary?) -> Void)?
    var onFailure: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    var onInfo: ((AMapNaviInfo?) -> Void)?

    private var bound = false
    private var pending: Place?
    private var pendingMode: TravelMode = .car
    private var pendingStart: CLLocationCoordinate2D?
    private var fallbackTried = false

    private var manager: AMapNaviDriveManager! { AMapNaviDriveManager.sharedInstance() }

    private func bind() {
        guard !bound else { return }
        bound = true
        manager.delegate = self
        manager.addDataRepresentative(self)
    }

    func plan(from: CLLocationCoordinate2D, to: Place, heading: Double, motorcycle: Bool) {
        bind()
        pending = to
        pendingStart = from
        pendingMode = motorcycle ? .motorcycle : .car
        fallbackTried = false
        drive(from: from, to: to, heading: heading, motorcycle: motorcycle)
    }

    private func drive(from: CLLocationCoordinate2D, to: Place, heading: Double, motorcycle: Bool) {
        if motorcycle {
            let v = AMapNaviVehicleInfo()
            v.type = 11
            v.vehicleId = MotorcycleProfile.plate
            v.motorcycleCC = MotorcycleProfile.displacement
            _ = manager.setVehicleInfo(v)
        }

        let start = AMapNaviPOIInfo()
        start.locPoint = AMapNaviPoint.location(withLatitude: CGFloat(from.latitude),
                                               longitude: CGFloat(from.longitude))
        start.startAngle = heading

        let end = AMapNaviPOIInfo()
        end.locPoint = AMapNaviPoint.location(withLatitude: CGFloat(to.latitude),
                                             longitude: CGFloat(to.longitude))
        if !to.id.isEmpty { end.mid = to.id }

        let strategy: AMapNaviDrivingStrategy = motorcycle ? .motorStrategyMultipleAvoidHighway : .drivingStrategyMultipleDefault
        manager.calculateDriveRoute(withStart: start, end: end, wayPOIInfos: nil, drivingStrategy: strategy)
    }

    func start() {
        // TODO: 导航启动接口签名待从头文件确认（本轮先用算路结果做预览）
    }

    func stop() {
        manager.stopNavi()
    }

    // MARK: AMapNaviDriveManagerDelegate

    func driveManager(_ driveManager: AMapNaviDriveManager!, onCalculateRouteSuccessWithType type: AMapNaviRoutePlanType) {
        guard let dest = pending else { return }
        let naviRoute: AMapNaviRoute? = driveManager.naviRoute
        guard let r = naviRoute else {
            onFailure?("路线数据为空")
            return
        }
        var coords: [CLLocationCoordinate2D] = []
        let points: [AMapNaviPoint] = r.routeCoordinates ?? []
        coords.reserveCapacity(points.count)
        for p in points {
            coords.append(CLLocationCoordinate2D(latitude: Double(p.latitude), longitude: Double(p.longitude)))
        }
        let summary = RouteSummary(mode: pendingMode,
                                   destination: dest,
                                   distance: Int(r.routeLength),
                                   duration: Int(r.routeTime),
                                   coordinates: coords)
        onRoute?(summary)
    }

    func driveManager(_ driveManager: AMapNaviDriveManager, onCalculateRouteFailure error: Error) {
        // 摩托车路网是收费接口，未开通时降级成汽车路网（避开高速），不让用户卡死
        if pendingMode == .motorcycle, !fallbackTried, let start = pendingStart, let dest = pending {
            fallbackTried = true
            onNotice?("摩托车专属路线未开通，已按汽车路网避开高速规划")
            drive(from: start, to: dest, heading: 0, motorcycle: false)
            pendingMode = .motorcycle
            return
        }
        onFailure?("算路失败，请检查网络后重试")
    }

    func driveManager(_ driveManager: AMapNaviDriveManager!, onArrive destinationPoint: AMapNaviPoint!) {
        onNotice?("已到达目的地")
    }

    // MARK: AMapNaviDriveDataRepresentable

    func driveManager(_ driveManager: AMapNaviDriveManager!, updateNaviInfo naviInfo: AMapNaviInfo!) {
        onInfo?(naviInfo)
    }
}

// MARK: - 电动车 / 骑行

final class RideAgent: NSObject, AMapNaviRideManagerDelegate, AMapNaviRideDataRepresentable {

    var onRoute: ((RouteSummary?) -> Void)?
    var onFailure: ((String) -> Void)?
    var onInfo: ((AMapNaviInfo?) -> Void)?

    private var bound = false
    private var pending: Place?

    private var manager: AMapNaviRideManager! { AMapNaviRideManager.sharedInstance() }

    private func bind() {
        guard !bound else { return }
        bound = true
        manager.delegate = self
        manager.addDataRepresentative(self)
    }

    func plan(from: CLLocationCoordinate2D, to: Place) {
        bind()
        pending = to

        let start = AMapNaviPOIInfo()
        start.locPoint = AMapNaviPoint.location(withLatitude: CGFloat(from.latitude),
                                               longitude: CGFloat(from.longitude))
        let end = AMapNaviPOIInfo()
        end.locPoint = AMapNaviPoint.location(withLatitude: CGFloat(to.latitude),
                                             longitude: CGFloat(to.longitude))
        if !to.id.isEmpty { end.mid = to.id }

        manager.calculateRideRoute(withStart: start, end: end, strategy: AMapNaviTravelStrategy.multipleDefault)
    }

    func start() {
        // TODO: 同上，骑行导航启动接口待确认
    }

    func stop() {
        manager.stopNavi()
    }

    // MARK: AMapNaviRideManagerDelegate

    func rideManager(onCalculateRouteSuccess rideManager: AMapNaviRideManager!) {
        guard let dest = pending, let r = rideManager.naviRoute else {
            onFailure?("路线数据为空")
            return
        }
        var coords: [CLLocationCoordinate2D] = []
        let points: [AMapNaviPoint] = r.routeCoordinates ?? []
        coords.reserveCapacity(points.count)
        for p in points {
            coords.append(CLLocationCoordinate2D(latitude: Double(p.latitude), longitude: Double(p.longitude)))
        }
        let summary = RouteSummary(mode: .ebike,
                                   destination: dest,
                                   distance: Int(r.routeLength),
                                   duration: Int(r.routeTime),
                                   coordinates: coords)
        onRoute?(summary)
    }

    func rideManager(_ rideManager: AMapNaviRideManager, onCalculateRouteFailure error: Error) {
        onFailure?("算路失败，请检查网络后重试")
    }

    // MARK: AMapNaviRideDataRepresentable

    func rideManager(_ rideManager: AMapNaviRideManager!, updateNaviInfo naviInfo: AMapNaviInfo!) {
        onInfo?(naviInfo)
    }
}
