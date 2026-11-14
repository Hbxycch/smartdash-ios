import Foundation
import CoreLocation
import Combine

/// 目的地搜索：关键词（带位置时走周边搜索，结果带距离）+ 分类快捷搜。
/// 走的是高德 Search SDK，与导航 SDK 共用同一个 Key。
final class PlaceSearchService: NSObject, ObservableObject {

    @Published private(set) var results: [Place] = []
    @Published private(set) var loading = false
    @Published private(set) var message: String?

    private var api: AMapSearchAPI!
    private var lastQuery: String = ""
    private var lastCenter: CLLocationCoordinate2D?

    override init() {
        super.init()
        api = AMapSearchAPI()
        api.delegate = self
    }

    /// 有关键词就搜；center 为 nil 时走全国关键词搜索（离线规划场景）
    func search(keyword: String, around center: CLLocationCoordinate2D?) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else {
            results = []
            message = nil
            return
        }
        guard AMapBootstrap.configured else {
            message = "未配置高德 Key，无法搜索目的地"
            return
        }

        lastQuery = kw
        lastCenter = center
        loading = true
        message = nil

        if let c = center {
            let req = AMapPOIAroundSearchRequest()
            req.keywords = kw
            req.types = "all"
            req.location = AMapGeoPoint.location(withLatitude: CGFloat(c.latitude),
                                                 longitude: CGFloat(c.longitude))
            req.radius = 30000      // 30km，跑长途时周边搜也能覆盖
            req.sortrule = 0        // 距离优先
            req.offset = 25
            api.aMapPOIAroundSearch(req)
        } else {
            let req = AMapPOIKeywordsSearchRequest()
            req.keywords = kw
            req.types = "all"
            req.city = "全国"
            req.offset = 25
            api.aMapPOIKeywordsSearch(req)
        }
    }

    func search(category: POICategory, around center: CLLocationCoordinate2D?) {
        search(keyword: category.keyword, around: center)
    }

    func retry() {
        guard !lastQuery.isEmpty else { return }
        search(keyword: lastQuery, around: lastCenter)
    }
}

extension PlaceSearchService: AMapSearchDelegate {

    func onPOISearchDone(_ request: AMapPOISearchBaseRequest!, response: AMapPOISearchResponse!) {
        loading = false
        let pois: [AMapPOI] = response?.pois ?? []
        results = pois.compactMap { Place.from($0) }
        if results.isEmpty {
            message = "没有找到「\(lastQuery)」，换个说法试试"
        }
    }

    func onPOISearchFailed(_ request: AMapPOISearchBaseRequest!, error: AMapSearchError!) {
        loading = false
        message = error?.description ?? "搜索失败，请检查网络或高德 Key 配置"

    }
}
