import SwiftUI

/// 控制器蓝牙连接页（整屏扫描，对应 Android 的 ControllerScanActivity）。
///
/// 与 BMS 的连接页不同：这里列出**所有**能搜到的蓝牙设备（不只智科），
/// 带信号柱 / dBm / 距离估算，按「仅智科」「强信号」筛选，点一行即连。
struct ControllerScanView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ctrl: ZhikeService
    @Environment(\.dismiss) private var dismiss

    @State private var filter: CtrlFilter = .all

    private var p: Palette { settings.palette }

    private var shown: [CtrlDevice] {
        switch filter {
        case .all: return ctrl.devices
        case .zhike: return ctrl.devices.filter { $0.isZhike }
        case .strong: return ctrl.devices.filter { $0.rssi >= -70 }
        }
    }

    var body: some View {
        ZStack {
            p.bgDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                chips
                Divider().overlay(p.stroke)
                list
                footer
            }
        }
        .onAppear {
            if !ctrl.isLive { ctrl.startScan() }
            BtLog.scan("打开控制器扫描页")
        }
        // 连上就自动退回仪表，状态交给顶栏胶囊显示
        .onChange(of: ctrl.state) { newState in
            if newState.isLive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dismiss() }
            }
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                ctrl.stopScan()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(p.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(p.panel))
                    .overlay(Circle().stroke(p.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Text("控制器蓝牙")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(p.textPrimary)

            Text(statusText)
                .font(.system(size: 12))
                .foregroundColor(p.textSecondary)
                .lineLimit(1)

            Spacer()

            Button {
                ctrl.startScan()
            } label: {
                Label(ctrl.state == .scanning ? "重新扫描" : "扫描", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(p.bgDeep)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(p.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(p.bg.opacity(0.9))
    }

    private var statusText: String {
        if case .scanning = ctrl.state {
            return "搜索中 · 已发现 \(ctrl.devices.count) 台"
        }
        if ctrl.devices.isEmpty { return "未发现设备" }
        return "已发现 \(ctrl.devices.count) 台"
    }

    // MARK: - 筛选

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(CtrlFilter.allCases) { f in
                Button {
                    filter = f
                } label: {
                    Text(f.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(filter == f ? p.bgDeep : p.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(filter == f ? p.accent : p.panel)
                        )
                        .overlay(
                            Capsule().stroke(filter == f ? Color.clear : p.stroke, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Text("智科控制器名字通常含 GEKOO / 智科")
                .font(.system(size: 11))
                .foregroundColor(p.textSecondary.opacity(0.8))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - 列表

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if shown.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(emptyText)
                            .font(.system(size: 13))
                            .foregroundColor(p.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }

                ForEach(shown) { dev in
                    row(dev)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var emptyText: String {
        if case .scanning = ctrl.state { return "正在搜索附近蓝牙设备…" }
        switch filter {
        case .zhike: return "没有发现智科控制器\n确认控制器已通电，或切到「全部」看看"
        case .strong: return "没有强信号设备\n靠近控制器再试，或切到「全部」"
        case .all: return "没有发现设备\n确认蓝牙已开启、控制器已通电"
        }
    }

    private func row(_ dev: CtrlDevice) -> some View {
        Button {
            BtLog.scan("选中控制器 \(dev.name) \(dev.idText)")
            ctrl.connect(dev)
        } label: {
            HStack(spacing: 12) {
                CtrlSignalBars(rssi: dev.rssi,
                               tint: barColor(dev.rssi),
                               dim: p.track)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(dev.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(p.textPrimary)
                            .lineLimit(1)
                        if dev.isZhike {
                            Text("智科")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(p.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(p.accent.opacity(0.14)))
                        }
                    }
                    Text("\(dev.idText) · \(dev.rssi) dBm · \(ctrlDistanceText(rssi: dev.rssi))")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundColor(p.textSecondary)
                }

                Spacer()

                if isConnecting(dev) {
                    Text("连接中…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(p.warn)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(p.textSecondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(p.panel.opacity(settings.darkTheme ? 0.92 : 0.98))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isConnecting(dev) ? p.accent : p.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func isConnecting(_ dev: CtrlDevice) -> Bool {
        guard case .connecting = ctrl.state else { return false }
        return ctrl.devices.contains { $0.id == dev.id }
    }

    private func barColor(_ rssi: Int) -> Color {
        if rssi >= -68 { return p.ok }
        if rssi >= -78 { return p.accent }
        if rssi >= -90 { return p.warn }
        return p.danger
    }

    // MARK: - 底部提示

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text("点设备即连接；连上后会自动回到仪表。若列表里没有智科控制器，确认控制器通电且没被其他手机占用。")
                .font(.system(size: 11))
            Spacer()
        }
        .foregroundColor(p.textSecondary.opacity(0.85))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(p.bg.opacity(0.9))
    }
}
