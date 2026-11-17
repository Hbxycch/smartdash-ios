import SwiftUI

/// 蓝牙连接日志页（对应 Android 的 BleLogActivity）。
///
/// 列表最新在上，BMS 青 / CTRL 黄 / SCAN 绿 / 其它灰；
/// 顶栏可导出（生成带头部的副本，走系统分享存到「文件」App 或直接发微信）与清空。
struct BleLogPage: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var lines: [String] = []
    @State private var exportURL: URL?
    @State private var confirmClear = false

    private var p: Palette { settings.palette }

    var body: some View {
        ZStack {
            p.bgDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(p.stroke)
                content
                footer
            }
        }
        .onAppear(perform: reload)
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 12) {
            Button {
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

            Text("蓝牙连接日志")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(p.textPrimary)

            Text("\(lines.count) 行 · \(BtLog.fileSize / 1024) KB")
                .font(.system(size: 11))
                .foregroundColor(p.textSecondary)
                .lineLimit(1)

            Spacer()

            ShareLink(item: exportURL ?? BtLog.fileURL, subject: Text("智能仪表 蓝牙连接日志")) {
                Label("导出", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(p.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(p.panel))
                    .overlay(Capsule().stroke(p.stroke, lineWidth: 1))
            }

            Button {
                confirmClear = true
            } label: {
                Label("清空", systemImage: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(p.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(p.panel))
                    .overlay(Capsule().stroke(p.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(p.bg.opacity(0.9))
        .alert("清空日志", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                BtLog.clear()
                reload()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本机全部蓝牙连接日志，删除后无法恢复。建议先导出。")
        }
    }

    // MARK: - 列表

    private var content: some View {
        ScrollView {
            if lines.isEmpty {
                VStack(spacing: 6) {
                    Text("还没有日志")
                        .font(.system(size: 14, weight: .medium))
                    Text("连接一次 BMS 或控制器后回到这里查看")
                        .font(.system(size: 12))
                }
                .foregroundColor(p.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(color(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.contains("[BMS]") { return p.accent }
        if line.contains("[CTRL]") { return p.warn }
        if line.contains("[SCAN]") { return p.ok }
        return p.textSecondary
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(p.accent).frame(width: 6, height: 6)
                Text("BMS").font(.system(size: 10)).foregroundColor(p.textSecondary)
                Circle().fill(p.warn).frame(width: 6, height: 6).padding(.leading, 6)
                Text("控制器").font(.system(size: 10)).foregroundColor(p.textSecondary)
                Circle().fill(p.ok).frame(width: 6, height: 6).padding(.leading, 6)
                Text("扫描").font(.system(size: 10)).foregroundColor(p.textSecondary)
                Spacer()
            }
            Text("导出会生成带机型/系统/版本头部的副本，可直接发微信或在「文件」App 的「智能仪表」文件夹里取。")
                .font(.system(size: 10))
                .foregroundColor(p.textSecondary.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(p.bg.opacity(0.9))
    }

    private func reload() {
        let all = BtLog.all()
        lines = Array(all.suffix(3000).reversed())
        exportURL = BtLog.export()
    }
}
