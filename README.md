# 智能车机系统 · iOS 版

Android 版（`../SmartDash-Android`，Android 工程目录）的功能对等移植：BLE 直连 JK-BMS / ANT-BMS，仪表盘 + 电芯 + 定位三页签，深/浅双主题与自定义背景图，电池化学体系 × 串数换算。

**开发方式：Windows 改代码 → GitHub Actions 的 macOS 机器编译 → 下载 unsigned IPA → 电脑端签名装到 iPhone。**

**命名约定**：代码工程名 / target / scheme = `SmartDash`（仪表台），桌面显示名仍是「智能车机」；Bundle ID = `com.smartdash.monitor.ios`（Android 端 applicationId = `com.smartdash.monitor`，同一品牌 + 平台后缀）。v4.3 起统一，上线后不可再改。

Windows 不能编 iOS，所以工程里不放 `.xcodeproj`，改用 `project.yml` + [XcodeGen](https://github.com/yonaskolb/XcodeGen)，由 CI 生成工程再编译。你本地只需要一个能编辑文本的工具。

---

## 一、你需要下载的东西

必需的两个（Windows 端签名安装）：

| 工具 | 用途 | 下载地址 |
|---|---|---|
| **Sideloadly** | 用 Apple ID 给 IPA 签名并装进 iPhone（首选，最省事） | https://sideloadly.io/ |
| **Apple 设备驱动** | Sideloadly 要能识别 iPhone；Win10 装 iTunes，Win11 装「Apple 设备」 | Win11：https://apps.microsoft.com/detail/9np83lwlpz9k <br> Win10：https://www.apple.com/itunes/download/win64 |

可选（替代方案 / 长期使用）：

| 工具 | 用途 | 下载地址 |
|---|---|---|
| AltStore + AltServer | 自动 7 天续签，不用每次手动装（免费账号也能用） | https://altstore.io/ |
| Git for Windows | 推送代码；多数机器已装，`git --version` 确认 | https://git-scm.com/download/win |
| GitHub CLI | 不想开网页时用 `gh` 建仓库 | https://cli.github.com/ |
| VS Code | 顺手改 Swift 代码（语法高亮有，补全一般） | https://code.visualstudio.com/ |

**不需要**下载 Xcode（30 GB+）、不需要 Mac、不需要越狱、不需要付费开发者账号。

---

## 二、一次性准备

```bash
# 1. 在 GitHub 网页上新建一个空仓库，例如 jkbms-ios（Private 也可以）
# 2. 本地初始化并推送（在本目录执行）
git init
git add -A
git commit -m "iOS v4.2 初始版本"
git branch -M main
git remote add origin https://github.com/<你的账号>/jkbms-ios.git
git push -u origin main
```

> Private 仓库的 Actions 额度：免费账号 2000 分钟/月，但 **macOS 机器按 10 倍计费**，即实际约 200 分钟。这个工程一次编译约 2–3 分钟（算 20–30 分钟额度），够用。想无限次编就把仓库设为 Public。

---

## 三、编译 → 装机（每次改完就走一遍）

1. **push 代码** → 打开仓库的 **Actions** 页 → `iOS Build` 自动开始。
2. 等 2–3 分钟变绿，进这次运行页面，底部 **Artifacts** 下载 `SmartDash-unsigned-ipa.zip`，解压得到 `SmartDash-unsigned.ipa`。
3. 数据线连 iPhone，打开 **Sideloadly**：
   - `IPA` 选刚下载的 ipa；
   - `Apple ID` 填你的 Apple ID（免费账号即可）；
   - 点 **Start**，按提示输入密码（双重认证要填专用密码或在手机上点允许）；
   - 手机上 **设置 → 通用 → VPN与设备管理 → 描述文件** 里点「信任」。
4. 打开 App，首次会请求蓝牙和定位权限，都允许。

**免费 Apple ID 的限制**（这是苹果的规则，不是 App 的问题）：

- 签名 **7 天过期**，过期后 App 打不开，需用 Sideloadly 重装一次（数据保留）；
- 同时最多 **3 个**自签 App；
- 后台蓝牙在锁屏后能维持一段时间，但长时间后台会被系统回收 —— 车机上要长期亮屏显示，建议插电 + 关闭自动锁屏（App 已设 `isIdleTimerDisabled`）。
- 想免掉 7 天限制：加入付费开发者计划（99 美元/年）或改用 **AltStore** 自动续签。

**打 tag 发版**（想要固定下载链接时）：

```bash
git tag v4.2 && git push origin v4.2
```

CI 会把 ipa 传到 GitHub Release，链接形如 `https://github.com/<账号>/jkbms-ios/releases/download/v4.2/SmartDash-unsigned.ipa`，这个地址可以直接填进设置页的「更新清单」。

---

## 四、工程结构

```
SmartDash-iOS/
├── project.yml                      XcodeGen 描述（bundle id / 版本号 / Info.plist 权限都在这里）
├── .github/workflows/ios.yml        编译 + 打包 unsigned IPA + 打 tag 发 Release
├── Sources/
│   ├── AppMain.swift                入口，注入 4 个环境对象
│   ├── Models/
│   │   ├── BmsSnapshot.swift        实时数据快照（极空/蚂蚁共用）
│   │   ├── BatteryProfile.swift     化学体系 × 串数 → 电压/SOC 换算
│   │   ├── BmsReadout.swift         快照 + 配置 → 界面显示值（含「估算」标记）
│   │   └── AppSettings.swift        UserDefaults 持久化配置
│   ├── BLE/
│   │   ├── BmsService.swift         CoreBluetooth 建链/订阅/轮询 + 演示数据
│   │   ├── JkBmsParser.swift        JK02 协议（300/320 字节帧，SUM8）
│   │   └── AntBmsParser.swift       蚂蚁协议（CRC-16/MODBUS，动态基址）
│   ├── Core/
│   │   ├── LocationService.swift    GPS 速度/航向/海拔 1Hz
│   │   └── UpdateChecker.swift      version.json 检查（只提示，不自装）
│   └── Views/
│       ├── RootView.swift           顶栏 + 页签 + 连接/设置入口
│       ├── DashboardPage.swift      码表 + 电量电压 + 地图（横竖屏自适应）
│       ├── GaugeView.swift          0-200 弧形表盘（Canvas 自绘）
│       ├── MapPanel.swift           MapKit 相机（车头朝上/北朝上）
│       ├── BatteryPage.swift        概览 + 电芯网格 + MOS 状态
│       ├── LocationPage.swift       大图 + 经纬度/海拔
│       ├── SettingsPage.swift       主题/电池/厂家/页签/地图/定位/升级
│       ├── ConnectSheet.swift       设备列表 + 演示模式
│       └── Theme.swift              深/浅配色与卡片样式
└── Support/Info.plist               由 xcodegen 生成，不要手改（改 project.yml）
```

## 五、与 Android 版的差异（有意为之）

| 项 | Android | iOS |
|---|---|---|
| 地图 | 高德 3D SDK（需 Key + 原生库） | **MapKit**，系统自带、无需 Key、无需下载 SDK |
| 更新 | 下载 APK 后自行拉起安装器 | 只能**检查 + 跳转下载**：iOS 不允许 App 自己装 App |
| 刹车 F/B | 占位（等 CAN/传感器） | 同样占位，只在信息条显示 `F -- / B --` |
| 后台 | 前台服务常驻 | `bluetooth-central` + `location` 后台模式，受系统调度 |
| 高德路况/导航 | 有 | MapKit 只做底图跟随，**不含转向导航** |

## 六、已知待办

- 无 App 图标（`Assets.xcassets` 未建），装上是白底默认图标；要图标就加一个 `AppIcon.appiconset` 并在 `project.yml` 里设 `ASSETCATALOG_COMPILER_APPICON_NAME`。
- 蚂蚁「自动协议」(`AntAutoProtocol`) 未移植，只支持 FFE0/FFE1 透传的型号。
- 云端同步/账号体系未做（与 Android 一致，后端尚未落地）。
- 真机未联调：协议解析是照 Android 版逐字段搬的，但 iOS 的 BLE 分片大小与 Android 不同，首次接板请开 `Console.app` 看是否 8 秒内进入「数据流」状态。
