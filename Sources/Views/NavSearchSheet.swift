import SwiftUI
import CoreLocation

/// 目的地搜索面板：分类快捷 / 收藏与最近 / 语音 / 键盘，四种入口都在这一页。
struct NavSearchSheet: View {

    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var favorites: FavoriteStore
    @Environment(\.dismiss) private var dismiss

    var center: CLLocationCoordinate2D?
    var onPick: (Place) -> Void

    @StateObject private var search = PlaceSearchService()
    @StateObject private var speech = SpeechInput()

    @State private var keyword = ""
    @State private var activeCategory: POICategory?
    @FocusState private var focused: Bool

    var body: some View {
        let p = settings.palette

        NavigationStack {
            VStack(spacing: 10) {
                searchField
                categoryRow
                Divider().overlay(p.stroke)
                content
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .background(p.bg.ignoresSafeArea())
            .navigationTitle("去哪儿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.foregroundColor(p.accent)
                }
            }
        }
        .onChange(of: speech.transcript) { text in
            guard !text.isEmpty, text != keyword else { return }
            keyword = text
            activeCategory = nil
            search.search(keyword: text, around: center)
        }
        .onDisappear { speech.stop() }
    }

    // MARK: - 搜索框

    private var searchField: some View {
        let p = settings.palette
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(p.textSecondary)

            TextField("搜地点、路名、POI", text: $keyword)
                .focused($focused)
                .submitLabel(.search)
                .foregroundColor(p.textPrimary)
                .onSubmit {
                    activeCategory = nil
                    search.search(keyword: keyword, around: center)
                }

            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    activeCategory = nil
                    search.search(keyword: "", around: center)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(p.textSecondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                speech.toggle()
            } label: {
                Image(systemName: speech.listening ? "waveform" : "mic.fill")
                    .foregroundColor(speech.listening ? p.danger : p.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(p.stroke, lineWidth: 1))
    }

    // MARK: - 分类

    private var categoryRow: some View {
        let p = settings.palette
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(POICategory.allCases) { c in
                    let on = activeCategory == c
                    Button {
                        activeCategory = c
                        keyword = c.title
                        focused = false
                        search.search(category: c, around: center)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: c.icon).font(.system(size: 12, weight: .semibold))
                            Text(c.title).font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(on ? p.bg : p.textPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(
                            Capsule().fill(on ? p.accent : p.panel)
                        )
                        .overlay(Capsule().stroke(on ? Color.clear : p.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        let p = settings.palette

        if let err = speech.errorText {
            banner(err, color: p.warn)
        }
        if let msg = search.message {
            banner(msg, color: p.textSecondary)
        }
        if !AMapBootstrap.configured {
            banner("未配置高德 Key（读到长度 \(AMapBootstrap.key.count)）：搜索与算路不可用", color: p.danger)
        }

        if search.loading {
            HStack(spacing: 8) {
                ProgressView().tint(p.accent)
                Text("搜索中…").font(.system(size: 13)).foregroundColor(p.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
        }

        ScrollView {
            LazyVStack(spacing: 8) {
                if !search.results.isEmpty {
                    ForEach(search.results) { place in
                        row(place)
                    }
                } else if keyword.isEmpty {
                    quickSection(title: "收藏", items: favorites.favorites)
                    quickSection(title: "最近去过", items: favorites.recents)
                }
            }
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private func quickSection(title: String, items: [Place]) -> some View {
        let p = settings.palette
        if !items.isEmpty {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(p.textSecondary)
                Spacer()
            }
            .padding(.top, 6)
            ForEach(items) { place in
                row(place)
            }
        }
    }

    private func row(_ place: Place) -> some View {
        let p = settings.palette
        return Button {
            favorites.remember(place)
            onPick(place)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(p.accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(p.textPrimary)
                        .lineLimit(1)
                    Text(place.displayAddress)
                        .font(.system(size: 12))
                        .foregroundColor(p.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if let d = place.distanceText {
                    Text(d)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(p.textSecondary)
                }

                Button {
                    favorites.toggleFavorite(place)
                } label: {
                    Image(systemName: favorites.isFavorite(place) ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundColor(favorites.isFavorite(place) ? p.warn : p.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.panel))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(p.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func banner(_ text: String, color: Color) -> some View {
        HStack {
            Text(text).font(.system(size: 12)).foregroundColor(color)
            Spacer()
        }
        .padding(.horizontal, 2)
    }
}
