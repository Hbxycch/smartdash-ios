import SwiftUI

/// 控制器蓝牙连接页（整屏扫描，对应 Android 的 ControllerScanActivity）。
///
/// 与 BMS 的连接页不同：这里列出**所有**能搜到的蓝牙设备（不只智科），
/// 带信号柱 / dBm / 距离估算，按「仅智科」「强信号」筛选。
/// 交互对齐 Android v5.42：点行只做「选中」（单选圆点，再点取消），
/// 真正连接由顶栏「连接」按钮发起；带自动连接开关与断开按钮。
struct ControllerScanView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ctrl: ZhikeService
    @Environment(\.dismiss) private var dismiss

    @State private var filter: CtrlFilter = .all
    /// 列表里当前选中、等待点「连接」的设备（nil = 未选择）
    @State private var selectedId: UUID? = nil

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

            // 连接按钮：选中才可用（未选择时置灰显示「未选择」）
            Button {
                connectSelected()
            } label: {
                Label(selectedDev == nil ? "未选择" : "连接", systemImage: "link")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(selectedDev == nil ? p.textSecondary : p.bgDeep)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(selectedDev == nil ? p.panel : p.accent)
                    )
                    .overlay(Capsule().stroke(selectedDev == nil ? p.stroke : Color.clear, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(selectedDev == nil)

            Button {
                ctrl.startScan()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(p.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(p.panel))
                    .overlay(Circle().stroke(p.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(p.bg.opacity(0.9))
    }

    /// 当前选中的设备（已离场则视为未选择）
    private var selectedDev: CtrlDevice? {
        guard let id = selectedId else { return nil }
        return ctrl.devices.first { $0.id == id }
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
            Spacer()
            // 自动连接开关（对齐 Android v5.42：控制器自动连接，持久化，默认开）
            Toggle(isOn: $settings.ctrlAutoConnect) {
                Text("自动连接")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(p.textSecondary)
            }
            .toggleStyle(.switch)
            .fixedSize()
            .onChange(of: settings.ctrlAutoConnect) { on in
                BtLog.ctrl("【自动连接】控制器自动连接 -> \(on ? "开" : "关")")
            }
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
        // 点行只做「选中」（再点一次取消），真正连接交给顶栏「连接」按钮
        let selected = selectedId == dev.id
        return Button {
            if selected {
                selectedId = nil
                BtLog.scan("取消选中 \(dev.name) \(dev.idText)")
            } else {
                selectedId = dev.id
                BtLog.scan("选中 \(dev.name) \(dev.idText)")
            }
        } label: {
            HStack(spacing: 12) {
                // 单选圆点
                Image(systemName: selected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(selected ? p.accent : p.textSecondary.opacity(0.5))

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
                    .stroke(isConnecting(dev) || selected ? p.accent : p.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func isConnecting(_ dev: CtrlDevice) -> Bool {
        guard case .connecting = ctrl.state else { return false }
        return ctrl.devices.contains { $0.id == dev.id }
    }

    /// 顶栏「连接」：一次写全连接意图，导出日志后单行即可还原「谁在什么时候连了什么」
    private func connectSelected() {
        guard let dev = selectedDev else {
            BtLog.scan("【连接】点击「连接」但未选择设备 · 控制器")
            return
        }
        BtLog.scan("【连接】点击「连接」· 控制器 · 选中 \(dev.name) \(dev.idText) rssi=\(dev.rssi)")
        ctrl.connect(dev)
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
            Text("点选设备后点右上「连接」；开启「自动连接」后下次启动自动连上次的控制器。")
                .font(.system(size: 11))
            Spacer()
            // 断开：有保存/在连的控制器才露出（对齐 Android v5.42；断开后保留 identifier 供自动重连）
            if !ctrl.savedId.isEmpty {
                Button {
                    BtLog.scan("【断开】扫描页：请求断开当前控制器 \(ctrl.savedId.prefix(8))")
                    ctrl.disconnect()
                } label: {
                    Label("断开", systemImage: "wifi.slash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(p.danger)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().stroke(p.danger.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundColor(p.textSecondary.opacity(0.85))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(p.bg.opacity(0.9))
    }
}
