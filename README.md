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

> **本机现状**：iTunes 已装在 `D:\Program Files\iTunes\iTunes.exe`，`Apple Mobile Device Service` 正在运行，驱动这关已经过了——插上 iPhone 后在「此电脑」里能看到 Apple iPhone 就说明 Sideloadly 能识别。
> Sideloadly 安装包已下载（`下载\SideloadlySetup64.exe`），双击装完即可；它只是签名工具，本身编不了 iOS。

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

1. 打开 https://github.com/new 新建空仓库，名字填 `smartdash-ios`，**不要**勾 README / .gitignore / License（勾了会跟本地历史冲突），Private 或 Public 都行。
2. 回到本目录，一条命令推上去：

```bash
./scripts/push.sh https://github.com/<你的账号>/smartdash-ios.git
```

脚本会做：设置提交身份（没配过也不会失败）→ 分支统一成 `main` → 绑定/更新 `origin` → 提交残留改动 → `git push` → 打印 Actions 地址。

> 首次 push 会弹 GitHub 登录窗口：浏览器授权即可（Git Credential Manager 会记住）。如果你开了两步验证又用密码推送失败，把仓库地址换成 SSH（`git@github.com:...`）或去 GitHub 生成 Personal Access Token 当密码用。

> Private 仓库的 Actions 额度：免费账号 2000 分钟/月，但 **macOS 机器按 10 倍计费**，即实际约 200 分钟。这个工程一次编译约 2–3 分钟（算 20–30 分钟额度），够用。想无限次编就把仓库设为 Public。

---

## 三、编译 → 装机（每次改完就走一遍）

1. **push 代码** → 打开仓库的 **Actions** 页 → `iOS Build` 自动开始。
2. 等 2–3 分钟变绿，进这次运行页面，底部 **Artifacts** 下载 `SmartDash-unsigned-ipa.zip`，解压得到 `SmartDash-unsigned.ipa`。
3. 数据线连 iPhone（**要解锁屏幕并点「信任此电脑」**），打开 **Sideloadly**：
   - `IPA` 选刚下载的 ipa；
   - 顶部设备下拉里选中你的 iPhone（列表是空的就先解决驱动/信任）；
   - `Apple ID` 填你的 Apple ID（免费账号即可）；
   - 点 **Start**，按提示输入密码（开了双重认证要填**专用密码**，或直接在手机上点允许）；
   - 手机上 **设置 → 通用 → VPN与设备管理 → 描述文件** 里点「信任」。
4. **打开开发者模式**（iOS 16 起必做，否则装上了也弹「需要开发者模式」打不开）：设置 → 隐私与安全性 → 拉到最底 → 开发者模式 → 打开 → 重启手机 → 重启后确认。
5. 打开 App，首次会请求蓝牙和定位权限，都允许。

**免费 Apple ID 的限制**（这是苹果的规则，不是 App 的问题）：

- 签名 **7 天过期**，过期后 App 打不开，需用 Sideloadly 重装一次（数据保留）；
- 同时最多 **3 个**自签 App；
- 后台蓝牙在锁屏后能维持一段时间，但长时间后台会被系统回收 —— 车机上要长期亮屏显示，建议插电 + 关闭自动锁屏（App 已设 `isIdleTimerDisabled`）。
- 想免掉 7 天限制：加入付费开发者计划（99 美元/年）或改用 **AltStore** 自动续签。

**打 tag 发版**（想要固定下载链接时）：

```bash
git tag v4.3 && git push origin v4.3
```

CI 会把 ipa 传到 GitHub Release，链接形如 `https://github.com/<账号>/smartdash-ios/releases/download/v4.3/SmartDash-unsigned.ipa`，这个地址可以直接填进设置页的「更新清单」。

---

## 四、工程结构

```
SmartDash-iOS/
├── project.yml                      XcodeGen 描述（bundle id / 版本号 / Info.plist 权限都在这里）
├── .github/workflows/ios.yml        编译 + 打包 unsigned IPA + 打 tag 发 Release
├── Sources/
│   ├── AppMain.swift                入口，注入 7 个环境对象（设置/蓝牙/定位/升级/导航/收藏/云同步）
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
│   ├── Net/
│   │   ├── CloudSync.swift          上位机上报：授权码激活、采样入队、批量上传、退避重试
│   │   ├── UploadQueue.swift        本地 JSONL 队列（先落盘、成功才删，断网不丢）
│   │   └── TelemetryMapping.swift   快照 → 接口字段（拿不到的量不传，绝不传 0）
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
- 云端上报：iOS 已能上报（设置 → 云同步，填服务器地址 + 授权码）；**Android 端还没写**。
- 上报用的是前台 URLSession：锁屏后系统挂起 App，补传要等下次回到前台；要真后台续传需换 background configuration（队列已落盘，不会丢数据）。
- 真机未联调：协议解析是照 Android 版逐字段搬的，但 iOS 的 BLE 分片大小与 Android 不同，首次接板请开 `Console.app` 看是否 8 秒内进入「数据流」状态。
