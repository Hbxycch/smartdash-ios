import Foundation
import Combine
import CoreBluetooth

enum LinkState: Equatable {
    case idle
    case scanning
    case connecting(String)
    case connected(String)          // 已建链、已订阅，尚无数据
    case streaming(String)
    case failed(String)

    var text: String {
        switch self {
        case .idle: return "未连接"
        case .scanning: return "搜索中…"
        case .connecting(let n): return "连接中 \(n)"
        case .connected(let n): return "已连接 \(n)"
        case .streaming(let n): return "数据流 \(n)"
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
    @Published private(set) var sourceLabel = "未连接"
    @Published private(set) var lastRSSI: Int = 0
    @Published var showAllDevices = false { didSet { if case .scanning = state { rescan() } } }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
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

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // ── 对外操作 ──

    func startScan(vendor: BatteryVendor) {
        self.vendor = vendor
        stopDemo()
        devices = []
        wantScan = true
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
        central.connect(p, options: nil)
    }

    func disconnect() {
        manualDisconnect = true
        stopDemo()
        stopTimers()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        writeChar = nil
        jk = nil
        ant = nil
        snapshot = BmsSnapshot()
        sourceLabel = "未连接"
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
                self.state = .failed("已连接但收不到数据：密码可能错误，或该设备不是所选厂家协议")
            }
        }
    }

    private func write(_ bytes: [UInt8], to p: CBPeripheral, ch: CBCharacteristic) {
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data(bytes), for: ch, type: type)
    }

    private func ingest(_ s: BmsSnapshot?) {
        guard let s else { return }
        snapshot = s
        watchdog?.invalidate()
        watchdog = nil
        let name = peripheral?.name ?? sourceLabel
        if !name.isEmpty, state != .streaming(name) { state = .streaming(name) }
    }

    private func stopTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        watchdog?.invalidate(); watchdog = nil
        rssiTimer?.invalidate(); rssiTimer = nil
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
        state = .connected(peripheral.name ?? "设备")
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
        startRSSI()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        state = .failed("连接失败：\(error?.localizedDescription ?? "未知原因")")
        stopTimers()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        stopTimers()
        writeChar = nil
        if manualDisconnect { manualDisconnect = false; return }   // 主动断开不报错
        if isDemo { return }
        state = .failed(error == nil ? "连接已断开" : "连接断开：\(error!.localizedDescription)")
    }
}

// MARK: - CBPeripheralDelegate

extension BmsService: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            state = .failed("发现服务失败：\(error!.localizedDescription)")
            return
        }
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            state = .failed("该设备没有 FFE0 服务，可能不是 JK/蚂蚁保护板")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.charUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else {
            state = .failed("发现特征失败：\(error!.localizedDescription)")
            return
        }
        guard let ch = service.characteristics?.first(where: { $0.uuid == Self.charUUID }) else {
            state = .failed("该设备没有 FFE1 特征")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        writeChar = ch
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
        peripheral.setNotifyValue(true, for: ch)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            state = .failed("订阅通知失败：\(error.localizedDescription)")
            return
        }
        if characteristic.isNotifying {
            sendReadyCommands()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        let bytes = [UInt8](data)
        let s = jk?.feed(bytes) ?? ant?.feed(bytes)
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
