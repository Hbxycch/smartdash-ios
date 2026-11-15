import Foundation
import Combine
import CoreBluetooth

enum LinkState: Equatable {
    case idle
    case scanning
    case connecting(String)
    case connected(String)          // 已建链、已订阅，尚无数据
    case streaming(String)
    case reconnecting(String, Int)  // 意外断开后自动重连（设备名, 第几次）
    case failed(String)

    var text: String {
        switch self {
        case .idle: return "未连接"
        case .scanning: return "搜索中…"
        case .connecting(let n): return "连接中 \(n)"
        case .connected(let n): return "已连接 \(n)"
        case .streaming(let n): return "数据流 \(n)"
        case .reconnecting(let n, let i): return "信号中断，重连 \(n)（第 \(i) 次）"
        case .failed(let m): return m
        }
    }

    var isBusy: Bool {
        switch self {
        case .scanning, .connecting: return true
        default: return false
        }
    }

    var isLive: Bool {
        switch self {
        case .streaming: return true
        default: return false
        }
    }
}

struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// 蓝牙链路 + 数据源。只负责建链/订阅/收发与状态机；
/// 具体发什么命令、怎么解析交给 JK / ANT 两个解析器。
final class BmsService: NSObject, ObservableObject {

    static let serviceUUID = CBUUID(string: "FFE0")
    static let charUUID = CBUUID(string: "FFE1")

    @Published private(set) var state: LinkState = .idle
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var snapshot = BmsSnapshot()
    @Published private(set) var sourceLabel = "BMS 未连接"
    @Published private(set) var lastRSSI: Int = 0
    @Published var showAllDevices = false { didSet { if case .scanning = state { rescan() } } }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var jk: JkBmsParser?
    private var ant: AntBmsParser?
    private var vendor: BatteryVendor = .jikong
    private var pollTimer: Timer?
    private var watchdog: Timer?
    private var demoTimer: Timer?
    private var rssiTimer: Timer?
    private var wantScan = false
    private var manualDisconnect = false
    private var demoState = DemoState(vendor: .jikong)
    private var found: [UUID: CBPeripheral] = [:]

    // ── 自动重连 ──
    private var reconnectTarget: CBPeripheral?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectTimer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        BtLog.log("===== 会话开始 =====")
    }

    // ── 对外操作 ──

    func startScan(vendor: BatteryVendor) {
        self.vendor = vendor
        stopDemo()
        cancelReconnect()
        devices = []
        wantScan = true
        BtLog.log("开始扫描 厂家=\(vendor == .ant ? "蚂蚁" : "极空") 全部设备=\(showAllDevices)")
        switch central.state {
        case .poweredOn:
            rescan()
        case .unauthorized:
            state = .failed("蓝牙权限被拒绝，请到设置-隐私-蓝牙中开启")
        case .poweredOff:
            state = .failed("蓝牙未开启")
        case .unsupported:
            state = .failed("此设备不支持蓝牙")
        default:
            // unknown / resetting：刚启动时状态还没就绪，等 didUpdateState 回来再扫
            state = .idle
        }
    }

    func stopScan() {
        wantScan = false
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(_ device: DiscoveredDevice) {
        // 防重复：正在连/已连同一台设备时直接忽略，避免产生第二条并行链路
        // （此前重复连接会导致两路解析互相干扰、连接页一直不退出）
        switch state {
        case .connecting, .connected, .streaming, .reconnecting:
            if peripheral?.identifier == device.id { return }
            cancelReconnect()
            disconnect()          // 换设备：先干净断开旧链路
        default:
            cancelReconnect()
        }
        central.stopScan()
        let p = found[device.id] ?? central.retrievePeripherals(withIdentifiers: [device.id]).first
        guard let p else {
            state = .failed("设备已不可见，请重新搜索")
            return
        }
        peripheral = p
        p.delegate = self
        state = .connecting(device.name)
        sourceLabel = device.name
        BtLog.log("发起连接 \(device.name) rssi=\(device.rssi)")
        central.connect(p, options: nil)
    }

    func disconnect() {
        manualDisconnect = true
        stopDemo()
        stopTimers()
        cancelReconnect()
        BtLog.log("主动断开 \(peripheral?.name ?? "")")
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        jk = nil
        ant = nil
        snapshot = BmsSnapshot()
        sourceLabel = "BMS 未连接"
        state = .idle
    }

    /// 演示模式：无保护板时验证界面
    func startDemo(vendor: BatteryVendor) {
        disconnect()
        self.vendor = vendor
        demoState = DemoState(vendor: vendor)
        sourceLabel = vendor == .ant ? "演示 · 蚂蚁 16S" : "演示 · 极空 4S"
        state = .streaming(sourceLabel)
        snapshot = demoState.step()
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.snapshot = self.demoState.step()
        }
    }

    func stopDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
    }

    var isDemo: Bool { demoTimer != nil }

    // ── 内部 ──

    private func rescan() {
        state = .scanning
        devices = []
        central.stopScan()
        let services: [CBUUID]? = showAllDevices ? nil : [Self.serviceUUID]
        central.scanForPeripherals(withServices: services,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func sendReadyCommands() {
        guard let p = peripheral, let ch = writeChar else { return }
        let cmds = jk?.readyCommands() ?? ant?.readyCommands() ?? []
        BtLog.log("发送就绪命令 \(cmds.count) 条")
        for (i, c) in cmds.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(i)) { [weak self] in
                self?.write(c, to: p, ch: ch)
            }
        }
        startPollTimer()
        startWatchdog()
    }

    private func startPollTimer() {
        pollTimer?.invalidate()
        guard let ant, let p = peripheral, let ch = writeChar else { return }
        let period = ant.pollPeriod
        guard period > 0, let cmd = ant.pollCommand() else { return }
        BtLog.log("启动轮询 周期=\(period)s 命令=\(BtLog.hex(cmd))")
        pollTimer = Timer.scheduledTimer(withTimeInterval: period, repeats: true) { [weak self] _ in
            self?.write(cmd, to: p, ch: ch)
        }
    }

    /// 建链后 8s 拿不到数据 → 判定密码错误或协议不符
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            if !self.snapshot.hasData {
                BtLog.log("看门狗超时：8s 未收到任何可解析数据")
                self.state = .failed("已连接但收不到数据：密码可能错误，或该设备不是所选厂家协议")
            }
        }
    }

    private func write(_ bytes: [UInt8], to p: CBPeripheral, ch: CBCharacteristic) {
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        BtLog.log("TX →\(ch.uuid) [\(type == .withoutResponse ? "noRsp" : "rsp")] \(BtLog.hex(bytes))")
        p.writeValue(Data(bytes), for: ch, type: type)
    }

    private func ingest(_ s: BmsSnapshot?) {
        guard let s else { return }
        snapshot = s
        watchdog?.invalidate()
        watchdog = nil
        let name = peripheral?.name ?? sourceLabel
        if !name.isEmpty, state != .streaming(name) {
            BtLog.log("首次解析成功 → 进入数据流 \(name)")
            // 数据恢复即视为重连成功
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            reconnectTarget = nil
            reconnectAttempts = 0
            state = .streaming(name)
        }
    }

    private func stopTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        watchdog?.invalidate(); watchdog = nil
        rssiTimer?.invalidate(); rssiTimer = nil
    }

    // ── 自动重连（信号差掉线时） ──

    private func cancelReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectTarget = nil
        reconnectAttempts = 0
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.attemptReconnect()
        }
    }

    private func attemptReconnect() {
        reconnectTimer = nil
        guard let p = reconnectTarget else { return }
        reconnectAttempts += 1
        let name = p.name ?? sourceLabel
        BtLog.log("自动重连 第\(reconnectAttempts)次 \(name)")
        state = .reconnecting(name, reconnectAttempts)
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    private func startRSSI() {
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.peripheral?.readRSSI()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BmsService: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantScan { rescan() }
        case .unauthorized:
            state = .failed("蓝牙权限被拒绝：设置 → 隐私与安全性 → 蓝牙")
        case .poweredOff:
            state = .failed("蓝牙未开启")
        case .unsupported:
            state = .failed("此设备不支持蓝牙")
        default:
            break                       // unknown / resetting：等系统回调，不误报
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? "未命名设备"
        let rssi = RSSI.intValue
        if rssi == 127 { return }                    // 无效信号
        found[peripheral.identifier] = peripheral
        if let idx = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[idx] = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: rssi)
        } else {
            devices.append(DiscoveredDevice(id: peripheral.identifier, name: name, rssi: rssi))
        }
        devices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        BtLog.log("已连接 \(peripheral.name ?? "?")，开始发现服务")
        state = .connected(peripheral.name ?? "设备")
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
        startRSSI()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        stopTimers()
        // 自动重连过程中的失败：还有次数就继续排下一次
        if reconnectTarget != nil, reconnectAttempts < maxReconnectAttempts {
            BtLog.log("重连失败 \(error?.localizedDescription ?? "未知原因")，3s 后再试")
            scheduleReconnect()
            return
        }
        cancelReconnect()
        BtLog.log("连接失败 \(error?.localizedDescription ?? "未知原因")")
        state = .failed("连接失败：\(error?.localizedDescription ?? "未知原因")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        stopTimers()
        writeChar = nil
        notifyChar = nil
        if manualDisconnect { manualDisconnect = false; return }   // 主动断开不报错
        if isDemo { return }
        let reason = error?.localizedDescription ?? "无错误"
        // 意外断开（信号差等）：自动重连，最多 5 次，每次间隔 3s
        if reconnectTarget == nil { reconnectTarget = peripheral }  // 首次掉线，锁定重连目标
        if reconnectAttempts < maxReconnectAttempts {
            BtLog.log("意外断开 \(reason)，3s 后自动重连")
            state = .reconnecting(peripheral.name ?? sourceLabel, reconnectAttempts + 1)
            scheduleReconnect()
        } else {
            BtLog.log("意外断开 \(reason)，重试 \(reconnectAttempts) 次仍失败")
            cancelReconnect()
            state = .failed("蓝牙信号过弱，重连 \(maxReconnectAttempts) 次失败：请靠近保护板后重新连接")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BmsService: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            BtLog.log("发现服务失败 \(error!.localizedDescription)")
            state = .failed("发现服务失败：\(error!.localizedDescription)")
            return
        }
        let svcUuids = peripheral.services?.map { $0.uuid.uuidString } ?? []
        BtLog.log("发现服务 \(svcUuids.joined(separator: ","))")
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            BtLog.log("无 FFE0 服务，断开")
            state = .failed("该设备没有 FFE0 服务，可能不是 JK/蚂蚁保护板")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        // 不带过滤发现全部特征：蚂蚁的 FFE0 下有两个同名 FFE1（一个只写、一个只通知），
        // 必须全部拿到后按属性区分，不能按顺序猜
        peripheral.discoverCharacteristics(nil, for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else {
            BtLog.log("发现特征失败 \(error!.localizedDescription)")
            state = .failed("发现特征失败：\(error!.localizedDescription)")
            return
        }
        let chars = service.characteristics ?? []
        for c in chars {
            var props: [String] = []
            if c.properties.contains(.read) { props.append("read") }
            if c.properties.contains(.write) { props.append("write") }
            if c.properties.contains(.writeWithoutResponse) { props.append("writeNoRsp") }
            if c.properties.contains(.notify) { props.append("notify") }
            BtLog.log("特征 \(c.uuid.uuidString) [\(props.joined(separator: "|"))]")
        }

        // 按属性挑：写特征要有 write/writeWithoutResponse，通知特征要有 notify
        var wch: CBCharacteristic?
        var nch: CBCharacteristic?
        for c in chars where c.uuid == Self.charUUID {
            if wch == nil && (c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)) { wch = c }
            if nch == nil && c.properties.contains(.notify) { nch = c }
        }
        // 单特征设备兜底（与 Android 端逻辑一致）
        if wch == nil { wch = nch }
        if nch == nil { nch = wch }
        guard let w = wch, let n = nch else {
            BtLog.log("无可用 FFE1 特征，断开")
            state = .failed("该设备没有 FFE1 特征")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        writeChar = w
        notifyChar = n
        // 按厂家建立解析器
        if vendor == .ant {
            let p = AntBmsParser()
            ant = p
            jk = nil
        } else {
            let p = JkBmsParser()
            jk = p
            ant = nil
        }
        BtLog.log("写特征=\(w.uuid.uuidString) 通知特征=\(n.uuid.uuidString) 订阅通知")
        peripheral.setNotifyValue(true, for: n)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            BtLog.log("订阅通知失败 \(error.localizedDescription)")
            state = .failed("订阅通知失败：\(error.localizedDescription)")
            return
        }
        if characteristic.isNotifying {
            BtLog.log("订阅成功 \(characteristic.uuid.uuidString)")
            sendReadyCommands()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            BtLog.log("读值错误 \(characteristic.uuid.uuidString) \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        let bytes = [UInt8](data)
        BtLog.log("RX ←\(characteristic.uuid.uuidString) \(BtLog.hex(bytes))")
        let s = jk?.feed(bytes) ?? ant?.feed(bytes)
        if s == nil {
            BtLog.log("RX 未能解析出快照（缓冲 \(jk?.bufferedCount ?? ant?.bufferedCount ?? 0) 字节）")
        }
        ingest(s)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        lastRSSI = RSSI.intValue
    }
}

// MARK: - 演示数据

private struct DemoState {
    var vendor: BatteryVendor
    var soc: Double = 87
    var socDrift: Double = -0.02
    var cellBase: Double = 3.321
    var cellWobble: Double = 0.0008
    var current: Double = 2.15
    var currentDrift: Double = -0.01
    var mos: Double = 31.5
    var t1: Double = 28.2
    var t2: Double = 27.8
    var speed: Double = 0

    init(vendor: BatteryVendor) {
        self.vendor = vendor
        if vendor == .ant {
            cellBase = 3.318
            current = 8.4
        }
    }

    mutating func step() -> BmsSnapshot {
        var d = BmsSnapshot()
        soc += socDrift
        if soc <= 80 { socDrift = 0.03 }
        if soc >= 88 { socDrift = -0.02 }
        current += currentDrift
        if current <= 1.2 { currentDrift = 0.02 }
        if current >= 3.0 { currentDrift = -0.015 }
        cellBase += cellWobble
        if cellBase <= 3.315 { cellWobble = 0.0009 }
        if cellBase >= 3.328 { cellWobble = -0.0008 }
        mos += Double.random(in: -0.05...0.05)
        t1 += Double.random(in: -0.04...0.04)
        t2 += Double.random(in: -0.04...0.04)

        d.soc = soc
        d.soh = 98
        d.cycles = 128
        d.passwordOk = true
        d.mosTemp = clamp(mos, 28, 38)
        d.current = current
        d.charging = current > 0.05

        if vendor == .ant {
            let n = 16
            var sum = 0.0, mn = Double.greatestFiniteMagnitude, mx = -Double.greatestFiniteMagnitude
            var mnIdx = 0, mxIdx = 0
            for i in 0..<n {
                let v = cellBase + (Double(i % 4) - 1.5) * 0.0022 + (i == 7 ? 0.004 : 0)
                d.cells[i] = v
                sum += v
                if v < mn { mn = v; mnIdx = i }
                if v > mx { mx = v; mxIdx = i }
            }
            d.cellCount = n
            d.totalVoltage = sum
            d.ratedAh = 280
            d.remainingAh = 280 * soc / 100
            d.powerWatt = sum * current
            d.maxCellV = mx; d.maxCellIdx = mxIdx
            d.minCellV = mn; d.minCellIdx = mnIdx
            d.avgCellV = sum / Double(n)
            d.cycleCapacityAh = 4820.6
            d.tempCount = 2
            d.temps[0] = clamp(t2, 24, 34)
            d.temps[1] = clamp(t2 - 0.6, 24, 34)
            d.balancerTemp = clamp(t1 + 1.4, 26, 36)
            d.statusText = current > 0.05 ? "充电中" : (current < -0.05 ? "放电中" : "静置")
            d.chargeMosOn = true; d.dischargeMosOn = true; d.balancerOn = true
            d.chargeMosText = "开启"; d.dischargeMosText = "开启"; d.balancerText = "自动均衡"
            d.balanceCellMask = 0b1000_0000
            d.deviceModel = "ANT-BLE24CBUB"
            d.firmware = "16ZMUB00-211026A"
        } else {
            d.cells[0] = cellBase
            d.cells[1] = cellBase - 0.003
            d.cells[2] = cellBase + 0.004
            d.cells[3] = cellBase - 0.002
            d.cellCount = 4
            d.balancingMask = 0b0010
            d.balancingAction = 1
            d.totalVoltage = d.cells[0] + d.cells[1] + d.cells[2] + d.cells[3]
            d.ratedAh = 52
            d.remainingAh = 52 * soc / 100
            d.fullChargeV = 14.60
            d.temp1 = clamp(t1, 25, 35)
            d.temp2 = clamp(t2, 25, 35)
            d.firmware = "JK02.3.6"
        }
        d.lastUpdate = Date()
        return d
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, v)) }
}
