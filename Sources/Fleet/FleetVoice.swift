import Foundation
import AVFoundation
import LiveKit

/// 语音对讲封装（LiveKit SFU @ NAS:7880），与 Android FleetVoice 同口径。
///
/// 语音模型：
///  · 进房间自动 connect（不发布麦克风），所有人自动订阅远端音频；
///  · PTT：按住 → 打开麦克风，松开 → 关闭（经典对讲机模型）；
///  · 外放：连接成功后置 .voiceChat + overrideOutputAudioPort(.speaker)，车机外放清晰。
///
/// LiveKit Swift SDK 全是 async 接口，这里用 Task 包成回调门面，
/// 页面侧不用接触并发细节。
final class FleetVoice: ObservableObject {

    @Published private(set) var ready = false
    @Published private(set) var pttOn = false

    private var room: Room?

    /// 连接（幂等：已连接直接回调成功）
    func connect(url: String, token: String, completion: @escaping (_ error: String?) -> Void) {
        if room != nil {
            ready = true
            completion(nil)
            return
        }
        Task {
            do {
                let r = Room()
                try await r.connect(url, token)
                // 车机外放：语音聊天模式 + 强制扬声器
                let s = AVAudioSession.sharedInstance()
                try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
                try? s.setActive(true)
                await MainActor.run {
                    self.room = r
                    self.ready = true
                    completion(nil)
                }
            } catch {
                await MainActor.run {
                    completion(error.localizedDescription)
                }
            }
        }
    }

    /// PTT：true=开始发布麦克风，false=停止。回调 ok 表示本次开关是否成功
    func setPtt(_ on: Bool, completion: @escaping (_ ok: Bool) -> Void) {
        guard let r = room else {
            completion(false)
            return
        }
        Task {
            do {
                try await r.localParticipant.set(source: .microphone, enabled: on)
                await MainActor.run {
                    self.pttOn = on
                    completion(true)
                }
            } catch {
                await MainActor.run {
                    completion(false)
                }
            }
        }
    }

    func disconnect() {
        guard let r = room else { return }
        room = nil
        ready = false
        pttOn = false
        Task {
            try? await r.disconnect()
        }
    }
}
