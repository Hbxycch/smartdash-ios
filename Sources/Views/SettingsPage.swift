import Foundation
import SwiftUI
import PhotosUI

struct SettingsPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var service: BmsService
    @EnvironmentObject var location: LocationService
    @EnvironmentObject var updater: UpdateChecker
    @EnvironmentObject var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss

    @State private var bgPickerItem: PhotosPickerItem?
    @State private var showConnect = false
    @State private var showLogPreview = false
    @State private var showLogPage = false
    @State private var showCrashPreview = false
    @State private var showScanner = false          // 授权码扫码
    @State private var showServerEditor = false     // 上报服务器地址编辑
    @State private var showUpdateEditor = false     // 检查更新地址编辑

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                batterySection
                sourceSection
                controllerSection
                tabsSection
                gaugeSection
                mapSection
                locationSection
                accountSection
                navSection
                logSection
                cloudSection
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
            .sheet(isPresented: $showScanner) {
                CodeScanSheet { code in
                    cloud.code = AuthCode.normalize(code)
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showServerEditor) {
                addressEditorSheet(
                    title: "云端服务器",
                    text: $cloud.baseURL,
                    hint: "默认不用填，App 直接使用内置服务器地址（页面上不显示具体地址）。\n要切换私有部署时再填：域名/端口即可，不用带 /api/v1。",
                    placeholder: "留空使用默认服务器；私有部署填 https://… 或 http://192.168.7.252:8081",
                    presented: $showServerEditor)
            }
            .sheet(isPresented: $showUpdateEditor) {
                addressEditorSheet(
                    title: "更新服务器地址",
                    text: $settings.updateManifestURL,
                    hint: "默认不用填，App 直接使用内置更新源检查新版本（页面上不显示具体地址）。\n要自建更新源时再填版本清单 JSON 的地址。",
                    placeholder: "留空使用默认更新源；或填 http://<主机IP>/ota/version.json",
                    presented: $showUpdateEditor)
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

    // MARK: - 控制器厂家

    private var controllerSection: some View {
        Section {
            // 自绘分段：未接入的厂家置灰不可点，并标注「未开放」
            HStack(spacing: 3) {
                ForEach(ControllerVendor.allCases) { v in
                    let sel = settings.controllerVendor == v
                    Button {
                        guard v.supported else { return }
                        settings.controllerVendor = v
                    } label: {
                        VStack(spacing: 1) {
                            Text(v.label)
                                .font(.system(size: 12, weight: sel ? .semibold : .regular))
                            if !v.supported {
                                Text("未开放")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundColor(settings.palette.textSecondary.opacity(0.8))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(sel ? settings.palette.accent.opacity(0.16) : Color.clear)
                        .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .disabled(!v.supported)
                    .opacity(v.supported ? 1 : 0.45)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10).fill(settings.palette.track))

            Text(controllerHint)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        } header: {
            Text("控制器")
        } footer: {
            Text("智科已接入：顶栏胶囊点开即可扫描控制器，选择设备后自动连接；仪表样式 2 右列显示控制器温度、电机转速、母线电流/电压、相线电流与故障码。其余厂家未开放。")
        }
    }

    private var controllerHint: String {
        switch settings.controllerVendor {
        case .fardriver:
            return "远驱未开放：iOS 端当前只支持智科控制器。"
        case .zhike:
            return "智科已接入：顶栏控制器胶囊 → 扫描并选择 GEKOO 设备；连上后右列显示温度/转速/母线/相电流/故障码。"
        case .lingbo:
            return "凌博未开放：iOS 端当前只支持智科控制器。"
        case .lande:
            return "蓝德未开放：iOS 端当前只支持智科控制器。"
        }
    }

    // MARK: - 用户账号

    @State private var showAccount = false

    private var accountSection: some View {
        Section {
            Button {
                showAccount = true
            } label: {
                HStack {
                    Label("用户账号", systemImage: "person.crop.circle")
                    Spacer()
                    Text(settings.isUserLoggedIn
                         ? "已登录：\(settings.userName)"
                         : (settings.userTrialDays > 0 ? "试用剩 \(settings.userTrialDays) 天" : "未注册 · 点此创建账号或登录"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
        } footer: {
            Text("注册自动获得 7 天免费试用；激活码与用户绑定、数据与设备绑定，一个账号可添加多辆车。")
        }
        .fullScreenCover(isPresented: $showAccount) {
            AccountPage()
                .environmentObject(settings)
                .environmentObject(cloud)
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

    // MARK: - 仪表控制

    private var gaugeSection: some View {
        Section("仪表控制") {
            // 与 Android 同款四选项分段：默认 / 经典 / 特斯拉 / CarPlay（后两项未开放，置灰）
            HStack(spacing: 4) {
                gaugeSeg(1, "默认")
                gaugeSeg(2, "经典")
                gaugeSeg(3, "特斯拉", locked: true)
                gaugeSeg(4, "CarPlay", locked: true)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.secondary.opacity(0.12)))
            Text("仪表首页的版式。默认：码表 + 地图；经典：三栏仪表（电量/电压/电流/温度 + 弧形码表）。特斯拉 / CarPlay 风格未开放。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func gaugeSeg(_ value: Int, _ title: String, locked: Bool = false) -> some View {
        let on = settings.gaugeStyle == value
        return Button {
            guard !locked else { return }
            settings.gaugeStyle = value
        } label: {
            Text(title)
                .font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundColor(locked ? .secondary.opacity(0.5)
                                 : (on ? .primary : .secondary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? Color.accentColor.opacity(0.85) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(locked)
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
        .sheet(isPresented: $showLogPage) {
            BleLogPage()
                .environmentObject(settings)
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
                Button {
                    showLogPage = true
                } label: {
                    Label("查看 / 导出连接日志", systemImage: "list.bullet.rectangle")
                }
                ShareLink(item: BtLog.fileURL, subject: Text("智能仪表 蓝牙连接日志")) {
                    Label("分享日志文件", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    BtLog.clear()
                } label: {
                    Label("清空日志", systemImage: "trash")
                }
            }
            Text("BMS、控制器、扫描三条链路都会记录：扫描、连接、特征订阅、每帧收发与解析结果。连不上时打开「查看 / 导出连接日志」，导出后直接发微信或存到「文件」App 即可。")
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

    // MARK: - 云同步

    private var cloudSection: some View {
        Section {
            Toggle(isOn: $cloud.enabled) {
                Label("上报到服务器", systemImage: "antenna.radiowaves.left.and.right")
            }

            if cloud.enabled {
                // 服务器地址：默认留空走内置（页面上不展示具体地址），私有部署再填（与 Android 同款）
                Button { showServerEditor = true } label: {
                    HStack {
                        Text("上报服务器地址")
                        Spacer()
                        Text(cloud.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "默认 · 使用内置服务器" : cloud.normalizedBaseURL)
                            .font(.system(size: 12))
                            .foregroundColor(cloud.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                                             ? .secondary : .accentColor)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    TextField("授权码 XXXXX-XXXXX-XXXXX-XXXXX-XXXXX", text: $cloud.code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                    // 扫后台「授权码 → 二维码」，识别后自动填入
                    Button {
                        showScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 18))
                    }
                    .accessibilityLabel("扫码填写授权码")
                }

                HStack {
                    Text("状态")
                    Spacer()
                    Text(cloud.phase.label)
                        .foregroundColor(phaseColor)
                }
                HStack {
                    Text("设备号")
                    Spacer()
                    Text(cloud.deviceNo)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("待上传")
                    Spacer()
                    Text("遥测 \(cloud.pendingTelemetry) · 轨迹 \(cloud.pendingTrack)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                if let t = cloud.lastUpload {
                    HStack {
                        Text("上次成功")
                        Spacer()
                        Text(t, style: .time)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                if !cloud.statusText.isEmpty {
                    Text(cloud.statusText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Button {
                    cloud.activate()
                } label: {
                    HStack {
                        Label(cloud.isActivated ? "已激活（失效后可重新激活）" : "用授权码激活",
                              systemImage: cloud.isActivated ? "checkmark.seal.fill" : "key")
                        Spacer()
                        if cloud.phase == .enrolling { ProgressView() }
                    }
                }
                .disabled(cloud.isActivated || cloud.code.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    cloud.uploadNow()
                } label: {
                    Label("立即上传", systemImage: "arrow.up.circle")
                }

                if cloud.pendingTotal > 0 {
                    Button(role: .destructive) {
                        cloud.clearQueues()
                    } label: {
                        Label("清空待传数据（\(cloud.pendingTotal) 条）", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("云同步")
        } footer: {
            Text("开着蓝牙在路上跑时，每 \(cloud.telemetryIntervalS) 秒从保护板取一个电池点、每 \(cloud.trackIntervalS) 秒取一个轨迹点，先存本机再批量上传。断网会一直攒着，联网后按采集时刻补传，不会丢也不会重复。授权码 25 位（5 组 × 5 位，字符集不含 0 1 5 A E I L N O S U Z），后台生成后可扫码或手抄填入，格式差异会自动归一。")
        }
    }

    private var phaseColor: Color {
        switch cloud.phase {
        case .ready: return .green
        case .failed: return .orange
        case .enrolling: return .blue
        case .needConfig, .off: return .secondary
        }
    }

    /// 地址编辑弹层（对齐 Android editCloudServer / editUpdateUrl：留空即恢复内置默认）
    private func addressEditorSheet(title: String, text: Binding<String>,
                                    hint: String, placeholder: String,
                                    presented: Binding<Bool>) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField(placeholder, text: text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text(hint)
                }
                Section {
                    Button(role: .destructive) {
                        text.wrappedValue = ""
                    } label: {
                        Text("清空，恢复使用内置默认")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { presented.wrappedValue = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - 升级

    private var updateSection: some View {
        Section("在线升级") {
            Toggle("启动时检查更新", isOn: $settings.autoCheckUpdate)
            // 更新源：默认留空走内置（页面上不展示具体地址），自建更新源再填（与 Android 同款）
            Button { showUpdateEditor = true } label: {
                HStack {
                    Text("检查更新地址")
                    Spacer()
                    Text(settings.updateManifestURL.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "默认 · 使用内置更新源" : settings.resolvedManifestURL)
                        .font(.system(size: 12))
                        .foregroundColor(settings.updateManifestURL.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? .secondary : .accentColor)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            Button {
                updater.check(manifestURL: settings.resolvedManifestURL, currentBuild: UpdateChecker.currentBuild)
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
            Text("智能仪表 · iOS 版。电池与轨迹默认只在本机处理；只有打开「云同步」并填了授权码，才会加密上报到你自己的服务器。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}
