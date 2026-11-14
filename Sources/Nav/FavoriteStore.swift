import Foundation
import Combine

/// 收藏点 + 最近去过。车机上键盘是兜底，这两个列表才是日常入口。
final class FavoriteStore: ObservableObject {

    @Published private(set) var favorites: [Place] = []
    @Published private(set) var recents: [Place] = []

    private let d = UserDefaults.standard
    private let favKey = "nav_favorites"
    private let recKey = "nav_recents"
    private let maxRecents = 8

    init() {
        favorites = decode(favKey)
        recents = decode(recKey)
    }

    func isFavorite(_ place: Place) -> Bool {
        favorites.contains { $0.id == place.id }
    }

    func toggleFavorite(_ place: Place) {
        if let idx = favorites.firstIndex(where: { $0.id == place.id }) {
            favorites.remove(at: idx)
        } else {
            favorites.append(place)
        }
        encode(favorites, favKey)
    }

    /// 发起导航时调用，自动去重并只留最近 8 条
    func remember(_ place: Place) {
        recents.removeAll { $0.id == place.id || $0.name == place.name }
        recents.insert(place, at: 0)
        if recents.count > maxRecents {
            recents = Array(recents.prefix(maxRecents))
        }
        encode(recents, recKey)
    }

    func clearRecents() {
        recents = []
        encode(recents, recKey)
    }

    private func decode(_ key: String) -> [Place] {
        guard let data = d.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Place].self, from: data)) ?? []
    }

    private func encode(_ list: [Place], _ key: String) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        d.set(data, forKey: key)
    }
}
