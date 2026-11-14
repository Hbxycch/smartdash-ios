import Foundation
import SwiftUI
import PhotosUI

struct SettingsPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var service: BmsService
    @EnvironmentObject var location: LocationService
    @EnvironmentObject var updater: UpdateChecker
    @Environment(\.dismiss) private var dismiss

    @State private var bgPickerItem: PhotosPickerItem?
    @State private var showConnect = false
    @State private var showLogPreview = false
    @State private var showCrashPreview = false

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                batterySection
                sourceSection
                tabsSection
                mapSection
                locationSection
                navSection
                logSection
                updateSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(settings.palette.bg)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("返回")
                                .font(.system(size: 15))
                        }
                    }
                    .foregroundColor(settings.palette.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(settings.palette.accent)
                }
            }
            .sheet(isPresented: $showConnect) {
                ConnectSheet()
                    .environmentObject(settings)
                    .environmentObject(service)
            }
            .onChange(of: bgPickerItem) { item in
                guard let item else { return }
                item.loadTransferable(type: Data.self) { result in
                    guard case .success(let data) = result, let data else { return }
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bg_import.jpg")
                    try? data.write(to: tmp)
                    DispatchQueue.main.async {
                        _ = settings.adoptBackgroundImage(from: tmp)
                        bgPickerItem = nil
                    }
                }
            }
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section("外观") {
            Toggle(isOn: $settings.darkTheme) {
                Label("深色主题", systemImage: settings.darkTheme ? "moon.fill" : "sun.max.fill")
            }
            PhotosPicker(selection: $bgPickerItem, matching: .images) {
                Label("自定义背景图", systemImage: "photo")
            }
            if settings.backgroundImageURL != nil {
                Button(role: .destructive) {
                    settings.clearBackgroundImage()
                } label: {
                    Label("移除背景图", systemImage: "trash")
                }
            }
            Text("背景图只作用于仪表页，会自动叠加深色遮罩保证数字可读。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 电池

    private var batterySection: some View {
        Section {
            Picker("化学体系", selection: $settings.chemistry) {
                ForEach(Chemistry.allCases) { c in
                    Text(c.shortLabel).tag(c)
                }
            }
            .pickerStyle(.segmented)

            Stepper(value: $settings.series, in: 1...BatteryProfile.maxSeries) {
                HStack {
                    Text("串数")
                    Spacer()
                    Text("\(settings.series) 串")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(BatteryProfile.packHint(settings.chemistry, settings.series))
                    .font(.system(size: 13, weight: .medium))
                Text(BatteryProfile.cellHint(settings.chemistry, settings.series))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)

            if settings.chemistry == .lead {
                Text("铅酸按 2V 单体计：12V 电池 = 6 串，48V = 24 串。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("电池设置")
        } footer: {
            Text("用于三件事：① 按串数算出额定/满充/欠压总压；② 保护板只报单体时用均值×串数兜底总压；③ 没有 SOC 时按开路电压曲线估算电量（会标注「估算」）。")
        }
    }

    // MARK: - 数据源

    private var sourceSection: some View {
        Section("保护板") {
            Picker("厂家", selection: $settings.vendor) {
                ForEach(BatteryVendor.allCases) { v in
                    Text(v.label).tag(v)
                }
            }
            Button {
                showConnect = true
            } label: {
                HStack {
                    Label("连接保护板", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    Text(service.state.text)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            if service.isDemo {
                Button(role: .destructive) {
                    service.disconnect()
                } label: {
                    Label("退出演示模式", systemImage: "xmark.circle")
                }
            }
            Text("极空与蚂蚁都用 FFE0/FFE1 透传特征。切换厂家后需要重新连接。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 页签

    private var tabsSection: some View {
        Section("页签") {
            Toggle("仪表", isOn: $settings.showDashboard)
            Toggle("电池信息", isOn: $settings.showBattery)
            Toggle("定位信息", isOn: $settings.showLocation)
            Picker("默认打开", selection: $settings.defaultTab) {
                ForEach(TabKind.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            Text("至少保留一个页签；关掉的页签不会出现在顶栏。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 地图

    private var mapSection: some View {
        Section("地图") {
            Picker("配色", selection: $settings.mapTheme) {
                ForEach(MapTheme.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            Toggle("车头朝上", isOn: $settings.headingUp)
            Text("自动配色按本地时间切换：6:00–18:00 白天，其余夜间。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 定位

    private var locationSection: some View {
        Section("定位") {
            Toggle("启用定位", isOn: $settings.locationEnabled)
                .onChange(of: settings.locationEnabled) { on in
                    location.start(enabled: on)
                }
            HStack {
                Text("授权状态")
                Spacer()
                Text(location.authorizationText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            if !location.authorized {
                Button("请求定位权限") { location.requestPermission() }
            }
            Text("速度用 GPS 而非轮速，所以隧道内会掉到 0；地图只在有定位时更新。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 导航（摩托车要车牌和排量才能算出合规路线）

    private var navSection: some View {
        Section {
            TextField("摩托车车牌", text: Binding(
                get: { MotorcycleProfile.plate },
                set: { MotorcycleProfile.plate = $0 }
            ))
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()

            Stepper(value: Binding(
                get: { MotorcycleProfile.displacement },
                set: { MotorcycleProfile.displacement = $0 }
            ), in: 50...2000, step: 50) {
                HStack {
                    Text("排量")
                    Spacer()
                    Text("\(MotorcycleProfile.displacement) cc")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("导航")
        } footer: {
            Text("摩托车路线要按车牌判断禁限行，排量影响匝道与高架的可通行性。导航入口在仪表页的地图上。")
        }
    }

    // MARK: - 蓝牙日志

    private var logSection: some View {
        Group {
            bleLogSection
            crashLogSection
        }
        .sheet(isPresented: $showLogPreview) {
            NavigationStack {
                ScrollView {
                    Text(BtLog.tailLines(200))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("最近 200 行")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showLogPreview = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showCrashPreview) {
            NavigationStack {
                ScrollView {
                    Text(CrashLogger.tailLines(300))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("崩溃记录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showCrashPreview = false }
                    }
                }
            }
        }
    }

    private var bleLogSection: some View {
        Section {
            Toggle("记录蓝牙日志", isOn: $settings.btLogEnabled)
            HStack {
                Text("日志文件")
                Spacer()
                Text(BtLog.fileSize > 0
                     ? ByteCountFormatter.string(fromByteCount: Int64(BtLog.fileSize), countStyle: .file)
                     : "暂无")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            if BtLog.fileSize > 0 {
                ShareLink(item: BtLog.fileURL, subject: Text("蓝牙日志")) {
                    Label("分享日志文件", systemImage: "square.and.arrow.up")
                }
                Button {
                    showLogPreview = true
                } label: {
                    Label("查看最近日志", systemImage: "doc.text.magnifyingglass")
                }
                Button(role: .destructive) {
                    BtLog.clear()
                } label: {
                    Label("清空日志", systemImage: "trash")
                }
            }
            Text("连接保护板时的每一步（扫描、连接、特征、收发的原始数据、解析结果）都会记录到日志。连不上时把日志文件发出来即可定位问题。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        } header: {
            Text("蓝牙日志")
        }
    }

    private var crashLogSection: some View {
        Section {
            if CrashLogger.fileSize > 0 {
                ShareLink(item: CrashLogger.fileURL, subject: Text("崩溃日志")) {
                    Label("分享崩溃日志", systemImage: "exclamationmark.triangle")
                }
                Button {
                    showCrashPreview = true
                } label: {
                    Label("查看崩溃记录", systemImage: "doc.text.magnifyingglass")
                }
                Button(role: .destructive) {
                    CrashLogger.clear()
                } label: {
                    Label("清空崩溃记录", systemImage: "trash")
                }
            } else {
                Text("暂无崩溃记录")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("崩溃日志")
        } footer: {
            Text("闪退时会把调用栈写在这里。下次闪退后进来分享这个文件，就能直接定位到出错代码。")
        }
    }

    // MARK: - 升级

    private var updateSection: some View {
        Section("在线升级") {
            Toggle("启动时检查更新", isOn: $settings.autoCheckUpdate)
            TextField("version.json 地址", text: $settings.updateManifestURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button {
                updater.check(manifestURL: settings.updateManifestURL, currentBuild: UpdateChecker.currentBuild)
            } label: {
                HStack {
                    Label("立即检查", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if updater.checking { ProgressView() }
                }
            }
            if let e = updater.errorText {
                Text(e).font(.system(size: 11)).foregroundColor(.secondary)
            }
            if let info = updater.latest {
                VStack(alignment: .leading, spacing: 4) {
                    Text("发现新版本 \(info.versionName)（\(info.versionCode)）")
                        .font(.system(size: 13, weight: .medium))
                    Text(info.changelog)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    if let url = info.downloadURL {
                        Link("前往下载", destination: url)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
            }
            Text("iOS 无法自己安装更新：正式渠道走 TestFlight，自签渠道需要用电脑端 Sideloadly / AltStore 重装。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text("\(UpdateChecker.currentVersion) (\(UpdateChecker.currentBuild))")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            HStack {
                Text("协议")
                Spacer()
                Text("JK02 / ANT-BLE")
                    .foregroundColor(.secondary)
            }
            Text("智能车机系统 · iOS 版。数据全部在本机处理，不上传云端。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}
