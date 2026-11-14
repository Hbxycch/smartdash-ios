import Foundation
import CoreLocation
import MapKit

// MARK: - 车型

/// 三种出行方式。高德侧用不同的导航管理器 + 策略来体现差异，这里只承载界面语义。
enum TravelMode: String, CaseIterable, Identifiable, Codable {
    case ebike
    case motorcycle
    case car

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ebike: return "电动车"
        case .motorcycle: return "摩托车"
        case .car: return "汽车"
        }
    }

    var icon: String {
        switch self {
        case .ebike: return "bolt.fill"
        case .motorcycle: return "bicycle"
        case .car: return "car.fill"
        }
    }

    /// 卡片副标题，一句话说明这条路线为什么不一样
    var note: String {
        switch self {
        case .ebike: return "走非机动车道"
        case .motorcycle: return "避开高速与快速路"
        case .car: return "综合最快"
        }
    }
}

// MARK: - 地点

/// 统一 POI 模型：搜索结果、收藏、最近记录都用它，存 UserDefaults 需要 Codable。
struct Place: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var distance: Int?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var distanceText: String? {
        guard let d = distance, d > 0 else { return nil }
        return d >= 1000 ? String(format: "%.1f km", Double(d) / 1000) : "\(d) m"
    }

    var displayAddress: String {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? "无详细地址" : a
    }

    /// 高德 POI → 内部模型。坐标非法直接丢弃，避免把 (0,0) 当目的地。
    static func from(_ poi: AMapPOI) -> Place? {
        guard let loc = poi.location else { return nil }
        let lat = Double(loc.latitude)
        let lon = Double(loc.longitude)
        guard lat != 0, lon != 0 else { return nil }
        let addr = poi.address ?? ""
        let city = poi.city ?? ""
        let rawDistance = poi.distance          // CGFloat，可能为 -1
        return Place(id: poi.uid ?? "\(lat),\(lon)",
                     name: poi.name ?? "未知地点",
                     address: addr.isEmpty ? city : addr,
                     latitude: lat,
                     longitude: lon,
                     distance: rawDistance > 0 ? Int(rawDistance.rounded()) : nil)
    }
}

// MARK: - 快捷分类

/// 车机上不该弹键盘，首页直接给一排大按钮。全部用关键词搜（比 POI 类型码稳，类型码会随高德版本变）。
enum POICategory: String, CaseIterable, Identifiable {
    case charge
    case swap
    case fuel
    case repair
    case hospital
    case restroom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .charge: return "充电站"
        case .swap: return "换电站"
        case .fuel: return "加油站"
        case .repair: return "维修"
        case .hospital: return "医院"
        case .restroom: return "卫生间"
        }
    }

    var keyword: String {
        switch self {
        case .charge: return "充电站"
        case .swap: return "换电站"
        case .fuel: return "加油站"
        case .repair: return "摩托车电动车维修"
        case .hospital: return "医院"
        case .restroom: return "公共厕所"
        }
    }

    var icon: String {
        switch self {
        case .charge: return "bolt.fill"
        case .swap: return "arrow.2.squarepath"
        case .fuel: return "fuelpump.fill"
        case .repair: return "wrench.fill"
        case .hospital: return "cross.case.fill"
        case .restroom: return "figure.walk"
        }
    }
}

// MARK: - 路线结果

struct RouteSummary {
    var mode: TravelMode
    var destination: Place
    var distance: Int                 // 米
    var duration: Int                 // 秒
    var coordinates: [CLLocationCoordinate2D]

    var distanceText: String {
        distance >= 1000 ? String(format: "%.1f km", Double(distance) / 1000) : "\(distance) m"
    }

    var durationText: String {
        let m = max(1, duration / 60)
        if m >= 60 { return "\(m / 60) 小时 \(m % 60) 分" }
        return "\(m) 分钟"
    }

    var etaText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date().addingTimeInterval(TimeInterval(duration)))
    }

    var polyline: MKPolyline {
        MKPolyline(coordinates: coordinates, count: coordinates.count)
    }
}
