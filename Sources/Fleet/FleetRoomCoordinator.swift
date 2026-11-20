import Foundation
import SwiftUI

/// 房间全局协调器：把 FleetRoomVM 的生命周期提升到 App 级。
/// 对齐 Android v5.46 的悬浮话筒：离开房间页不再断链（聊天 / 语音 / 位置上报继续跑），
/// 主界面挂悬浮话筒，点击直达房间页；退出车队 / 结束车队时彻底停链。
@MainActor
final class FleetRoomCoordinator: ObservableObject {

    @Published private(set) var vm: FleetRoomVM?
    /// 悬浮话筒发起的「直达房间」请求，由 FleetPage onAppear / refresh 消费
    @Published var wantsRoomJump = false

    var inRoom: Bool { vm != nil }

    /// 拿本房间对应的 VM：同房间复用（不重复建链），换房间才重建
    func roomVM(_ fleet: [String: Any]) -> FleetRoomVM {
        let code = fleet["roomCode"] as? String ?? ""
        if let v = vm, v.roomCode == code { return v }
        vm?.stop()
        let v = FleetRoomVM()
        vm = v
        return v
    }

    /// 退出车队 / 结束车队时调用：彻底停链并清引用（悬浮话筒随之消失）
    func closeRoom() {
        vm?.stop()
        vm = nil
        wantsRoomJump = false
    }
}

/// 应用内悬浮话筒（对应 Android 的 FleetMicFloat）：
/// 房间在后台运行时挂在主界面右下，可拖动（位置落盘），点击直达车队房间页。
struct FleetMicFloat: View {
    var onTap: () -> Void

    @AppStorage("fleet_mic_x") private var savedX: Double = -1
    @AppStorage("fleet_mic_y") private var savedY: Double = -1
    @State private var pos: CGPoint = .zero
    @State private var dragBase: CGPoint?
    @State private var primed = false

    var body: some View {
        GeometryReader { geo in
            let defaultPos = CGPoint(x: geo.size.width - 66, y: geo.size.height - 130)
            let current: CGPoint = primed
                ? clamped(pos, geo)
                : (savedX >= 0 ? clamped(CGPoint(x: savedX, y: savedY), geo) : defaultPos)
            mic(current: current, geo: geo)
                .position(current)
        }
    }

    private func clamped(_ p: CGPoint, _ geo: GeometryProxy) -> CGPoint {
        CGPoint(x: min(max(40, p.x), geo.size.width - 40),
                y: min(max(80, p.y), geo.size.height - 60))
    }

    private func mic(current: CGPoint, geo: GeometryProxy) -> some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 56, height: 56)
            .background(Circle().fill(Color(red: 0.30, green: 0.85, blue: 0.82).opacity(0.92)))
            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragBase == nil { dragBase = current }
                        if let b = dragBase {
                            pos = clamped(CGPoint(x: b.x + g.translation.width,
                                                  y: b.y + g.translation.height), geo)
                            primed = true
                        }
                    }
                    .onEnded { g in
                        if abs(g.translation.width) < 8, abs(g.translation.height) < 8 {
                            onTap()   // 没怎么动 → 当作点击
                        } else if primed {
                            savedX = pos.x
                            savedY = pos.y
                        }
                        dragBase = nil
                    }
            )
    }
}
