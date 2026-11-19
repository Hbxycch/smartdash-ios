import Foundation
import UIKit
import CoreBluetooth
import CoreLocation

/// 设备诊断快照：反馈提交时静默附带，界面不展示，仅后台可见。
/// 目的：后台按硬件/系统/权限/链路实际情况复现问题。
/// 约定：任何一项取不到只跳过该项，绝不抛错、绝不影响提交。
enum DeviceDiag {

    private static func machine() -> String {
        var uts = utsname()
        uname(&uts)
        let id = withUnsafeBytes(of: &uts.machine) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        return id
    }

    private static func mb(_ bytes: Int64) -> Int64 { bytes / 1_048_576 }

    static func snapshot(settings: AppSettings, cloud: CloudSync,
                         baseURL: String) -> [String: Any] {
        var o: [String: Any] = ["platform": "ios"]

        // ── 机型与系统 ──
        let dev = UIDevice.current
        o["device"] = [
            "hwModel": machine(),
            "model": dev.model,
            "name": dev.name,
            "idiom": dev.userInterfaceIdiom == .pad ? "pad" : "phone",
            "systemName": dev.systemName,
            "systemVersion": dev.systemVersion,
        ]

        // ── 屏幕 ──
        let scr = UIScreen.main
        o["screen"] = [
            "widthPt": Int(scr.bounds.width),
            "heightPt": Int(scr.bounds.height),
            "nativeWidthPx": Int(scr.nativeBounds.width),
            "nativeHeightPx": Int(scr.nativeBounds.height),
            "scale": Double(scr.scale),
            "brightness": Double(round(scr.brightness * 100) / 100),
        ]

        // ── 硬件资源 ──
        let pi = ProcessInfo.processInfo
        var perf: [String: Any] = [
            "cores": pi.processorCount,
            "activeCores": pi.activeProcessorCount,
            "physicalMemoryMB": mb(Int64(pi.physicalMemory)),
            "uptimeMin": Int(pi.systemUptime / 60),
            "lowPowerMode": pi.isLowPowerModeEnabled,
            "thermalState": "\(pi.thermalState.rawValue)",
        ]
        if let disk = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = disk[.systemFreeSize] as? Int64,
           let total = disk[.systemSize] as? Int64 {
            perf["diskFreeMB"] = mb(free)
            perf["diskTotalMB"] = mb(total)
        }
        o["hardware"] = perf

        // ── 语言 / 时区 / 字体 ──
        o["env"] = [
            "locale": Locale.current.identifier,
            "language": Locale.preferredLanguages.first ?? "",
            "timezone": TimeZone.current.identifier,
            "contentSizeCategory": UIApplication.shared.preferredContentSizeCategory.rawValue,
        ]

        // ── App 版本 ──
        o["app"] = [
            "versionName": UpdateChecker.currentVersion,
            "versionCode": UpdateChecker.currentBuild,
        ]

        // ── 业务配置 ──
        o["config"] = [
            "deviceNo": cloud.deviceNo,
            "bmsVendor": settings.vendor.label,
            "ctrlVendor": settings.controllerVendor.label,
            "gaugeStyle": settings.gaugeStyle,
            "voiceFreeMic": settings.voiceFreeMic,
            "authExpiresAt": settings.deviceAuthExpires,
            "boundVehicle": settings.boundVehicle,
            "cloudBaseURL": baseURL,
            "syncPhase": phaseText(cloud.phase),
        ]

        // ── 权限与开关 ──
        var perm: [String: Any] = [:]
        switch CLLocationManager.authorizationStatus() {
        case .authorizedAlways: perm["location"] = "always"
        case .authorizedWhenInUse: perm["location"] = "whenInUse"
        case .denied: perm["location"] = "denied"
        case .restricted: perm["location"] = "restricted"
        case .notDetermined: perm["location"] = "notDetermined"
        @unknown default: perm["location"] = "unknown"
        }
        if #available(iOS 13.1, *) {
            switch CBManager.authorization {
            case .allowedAlways: perm["bluetooth"] = "allowed"
            case .denied: perm["bluetooth"] = "denied"
            case .restricted: perm["bluetooth"] = "restricted"
            case .notDetermined: perm["bluetooth"] = "notDetermined"
            @unknown default: perm["bluetooth"] = "unknown"
            }
        }
        o["permissions"] = perm

        return o
    }

    private static func phaseText(_ p: CloudSync.Phase) -> String {
        switch p {
        case .off: return "off"
        case .needConfig: return "needConfig"
        case .enrolling: return "enrolling"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
}
