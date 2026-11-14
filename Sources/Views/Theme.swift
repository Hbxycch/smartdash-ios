import Foundation
import SwiftUI
import UIKit

/// 深/浅两套配色，对应 Android 的 values / values-notnight。
struct Palette {
    let dark: Bool
    var bg: Color { dark ? Color(hex: 0x0B0F14) : Color(hex: 0xF2F5F8) }
    var bgDeep: Color { dark ? Color(hex: 0x070A0E) : Color(hex: 0xE7ECF1) }
    var panel: Color { dark ? Color(hex: 0x141A22) : Color(hex: 0xFFFFFF) }
    var panelAlt: Color { dark ? Color(hex: 0x1B2430) : Color(hex: 0xF7F9FB) }
    var stroke: Color { dark ? Color(hex: 0x25313F) : Color(hex: 0xDCE3EA) }
    var textPrimary: Color { dark ? Color(hex: 0xE8EEF6) : Color(hex: 0x16202B) }
    var textSecondary: Color { dark ? Color(hex: 0x8A99AB) : Color(hex: 0x6B7A8C) }
    var accent: Color { dark ? Color(hex: 0x35D6E8) : Color(hex: 0x0E8FA8) }
    var ok: Color { dark ? Color(hex: 0x35D07F) : Color(hex: 0x1BA362) }
    var warn: Color { dark ? Color(hex: 0xFFB020) : Color(hex: 0xD98600) }
    var danger: Color { dark ? Color(hex: 0xFF4D4F) : Color(hex: 0xD42A2A) }
    var track: Color { dark ? Color(hex: 0x1E2833) : Color(hex: 0xE3E9EF) }
    var redZone: Color { dark ? Color(hex: 0xF2544F) : Color(hex: 0xD93A34) }

    func socColor(_ level: BmsReadout.SocLevel) -> Color {
        switch level {
        case .good: return ok
        case .ok: return accent
        case .low: return warn
        case .critical: return danger
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// 通用卡片底：圆角 + 描边 + 可选模糊
struct CardBackground: ViewModifier {
    @EnvironmentObject var settings: AppSettings
    var padding: CGFloat = 14
    var radius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(settings.palette.panel.opacity(settings.darkTheme ? 0.92 : 0.98))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(settings.palette.stroke, lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 14, radius: CGFloat = 16) -> some View {
        modifier(CardBackground(padding: padding, radius: radius))
    }
}

/// 仪表页底层：纯色 → 自定义背景图（带深色遮罩保证可读性）
struct DashboardBackground: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ZStack {
            settings.palette.bgDeep
            if let url = settings.backgroundImageURL, let ui = UIImage(contentsOfFile: url.path) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .overlay(
                        LinearGradient(colors: [Color.black.opacity(0.55), Color.black.opacity(0.25)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .clipped()
            }
        }
        .ignoresSafeArea()
    }
}
