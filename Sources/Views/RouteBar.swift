import SwiftUI

/// 地图下方的路线条：车型切换 / 距离时间 / 开始导航。
/// 这是「怎么导航」的核心入口，所有状态都在这一张卡里收敛。
struct RouteBar: View {

    @EnvironmentObject var settings: AppSettings
    @ObservedObject var navi: NavigationController
    var onSearch: () -> Void

    var body: some View {
        let p = settings.palette

        VStack(spacing: 10) {
            modeRow

            if navi.planning {
                HStack(spacing: 8) {
                    ProgressView().tint(p.accent)
                    Text("正在规划路线…")
                        .font(.system(size: 13))
                        .foregroundColor(p.textSecondary)
                    Spacer()
                }
            } else if let err = navi.planError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                    Text(err)
                        .font(.system(size: 12))
                        .lineLimit(2)
                    Spacer()
                    Button("重试") { retry() }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(p.accent)
                }
                .foregroundColor(p.warn)
            } else if let route = navi.route {
                summaryRow(route)
                actionRow(route)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "location.magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundColor(p.textSecondary)
                    Text("搜一个目的地开始导航")
                        .font(.system(size: 13))
                        .foregroundColor(p.textSecondary)
                    Spacer()
                    Button(action: onSearch) {
                        Text("搜索")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(p.bg)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(Capsule().fill(p.accent))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let note = navi.notice {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").font(.system(size: 11))
                    Text(note).font(.system(size: 11)).lineLimit(2)
                    Spacer()
                }
                .foregroundColor(p.warn)
            }
        }
        .card(padding: 10, radius: 14)
    }

    // MARK: - 车型

    private var modeRow: some View {
        let p = settings.palette
        return HStack(spacing: 8) {
            ForEach(TravelMode.allCases) { m in
                let on = navi.mode == m
                Button {
                    guard navi.mode != m else { return }
                    if navi.route != nil {
                        navi.replan(for: m)
                    } else {
                        navi.mode = m
                    }
                } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: m.icon).font(.system(size: 11, weight: .semibold))
                            Text(m.title).font(.system(size: 13, weight: .semibold))
                        }
                        Text(m.note)
                            .font(.system(size: 9))
                            .opacity(on ? 0.85 : 0.55)
                    }
                    .foregroundColor(on ? p.bg : p.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(on ? p.accent : p.panelAlt)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 摘要

    private func summaryRow(_ route: RouteSummary) -> some View {
        let p = settings.palette
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(route.distanceText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(p.textPrimary)
                Text("总里程")
                    .font(.system(size: 9))
                    .foregroundColor(p.textSecondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(route.durationText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(p.accent)
                Text("预计用时")
                    .font(.system(size: 9))
                    .foregroundColor(p.textSecondary)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(route.etaText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(p.textPrimary)
                Text("预计到达")
                    .font(.system(size: 9))
                    .foregroundColor(p.textSecondary)
            }
        }
    }

    private func actionRow(_ route: RouteSummary) -> some View {
        let p = settings.palette
        return HStack(spacing: 8) {
            Button {
                navi.startNavigation()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: navi.navigating ? "stop.fill" : "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(navi.navigating ? "结束导航" : "开始导航")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(p.bg)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(navi.navigating ? p.danger : p.ok)
                )
            }
            .buttonStyle(.plain)

            Button {
                navi.stopNavigation()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(p.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous).fill(p.panelAlt)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func retry() {
        onSearch()
    }
}
