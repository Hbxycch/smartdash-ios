import Foundation
import Combine
import CoreBluetooth

/// 扫描列表里的一行控制器设备。
/// iOS 不暴露 MAC，用 identifier 前 8 位代替（同一台车机内保持稳定，足够辨认）。
struct CtrlDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let isZhike: Bool

    var idText: String { String(id.uuidString.prefix(8)) }
}

/// 扫描页筛选
enum CtrlFilter: String, CaseIterable, Identifiable {
    case all, zhike, strong
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "全部"
        case .zhike: return "仅智科"
        case .strong: return "强信号"
        }
    }
}

/// 一帧解码后的快照（struct，便于 SwiftUI 直接刷新）
struct ZhikeReadout: Equatable {
    var valid = false
    var rpm: Double = 0
    var busVoltageV: Double = 0
    var busCurrentA: Double = 0
    var tempC: Double?
    var phaseCurrentA: Double?
    var faultBits = 0
    var regen = false
}

/// 智科控制器 BLE 链路（与 Android 的 ZhikeBleClient 对齐）。
///
///   · 开启帧 01 02 → 写 FFE2（无 FFE2 时退化写 FFE1）
///   · 轮询帧 AA 13 FF 01 AA 13 00 01 → 每 200ms 写 FFE1
///   · 数据帧 67 字节从 notify 特征返回
///
/// iOS 的 CoreBluetooth 由系统串行化 GATT 操作，不需要像 Android 那样手动排队。
final class ZhikeService: NSObject, ObservableObject {

    static let ffe1 = CBUUID(string: "FFE1")
    static let ffe2 = CBUUID(string: "FFE2")

    private static let cmdInit: [UInt8] = [0x01, 0x02]
    private static let cmdPoll: [UInt8] = [0xAA, 0x13, 0xFF, 0x01, 0xAA, 0x13, 0x00, 0x01]
    private static let pollInterval: TimeInterval = 0.2
    private static let dataTimeout: TimeInterval = 10
    private static let reconnectDelay: TimeInterval = 3

    @Published private(set) var state: LinkState = .idle
    /// 已发现设备：智科名字的排前面，其余按信号强→弱
    @Published private(set) var devices: [CtrlDevice] = []
    @Published private(set) var readout = ZhikeReadout()
    @Published private(set) var connectedName = ""

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var initChar: CBCharacteristic?
    private var notifyChars: [CBCharacteristic] = []
    private var pendingServices: [CBService] = []
    private var allChars: [CBCharacteristic] = []
    private var subscribedCount = 0

    private var pollTimer: Timer?
    private var watchdog: Timer?
    private var reconnectTimer: Timer?
    private var scanTimeout: Timer?

    private var wantScan = false
    private var manualDisconnect = false
    private var sessionStarted = false
    private var forceResponseWrite = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    private var found: [UUID: CBPeripheral] = [:]
    private var rxCount = 0
    private var txCount = 0
    private var txFail = 0

    private let decoder = ZhikeController()
    private let assembler = ZhikeController.Assembler()

    /// 上次连过的设备 identifier，用于绕过扫描直接重连
    private let savedKey = "ctrl_peripheral_id"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // ── 对外状态 ──

    var isLive: Bool { state.isLive }

    var pillText: String {
        switch state {
        case .idle: return "控制器未连接"
        case .scanning: return "控制器搜索中…"
        case .connecting: return "控制器连接中…"
        case .connected: return "控制器已连接"
        case .streaming: return connectedName.isEmpty ? "控制器已连接" : connectedName
        case .reconnecting: return "控制器重连中…"
        case .failed: return "控制器未连接"
        }
    }

    var pillColorIsActive: Bool {
        if case .streaming = state { return true }
        if case .connected = state { return true }
        return false
    }

    var pillNeedsWarn: Bool {
        switch state {
        case .connecting, .scanning, .reconnecting: return true
        default: return false
        }
    }

    // ── 扫描 ──

    func startScan() {
        manualDisconnect = false
        devices = []
        found.removeAll()
        wantScan = true
        BtLog.scan("控制器扫描开始（30s）")
        switch central.state {
        case .poweredOn:
            beginScan()
        case .unauthorized:
            state = .failed("蓝牙权限被拒绝，请到设置-隐私-蓝牙中开启")
        case .poweredOff:
            state = .failed("蓝牙未开启")
        case .unsupported:
            state = .failed("此设备不支持蓝牙")
        default:
            break                            // 等 didUpdateState 回来再扫
        }
    }

    func stopScan() {
        wantScan = false
        scanTimeout?.invalidate()
        scanTimeout = nil
        if central.state == .poweredOn { central.stopScan() }
        if case .scanning = state { state = .idle }
        BtLog.scan("控制器扫描停止，共 \(devices.count) 台")
    }

    private func beginScan() {
        if case .streaming = state { return }        // 已连上就别再扫，省射频
        state = .scanning
        central.stopScan()
        // 不过滤服务：中继/新固件不一定广播 FFE0，按名字识别智科，其余照常列出
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanTimeout?.invalidate()
        scanTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.stopScan()
        }
    }

    // ── 连接 ──

    func connect(_ dev: CtrlDevice) {
        central.stopScan()
        stopScan()
        guard let p = found[dev.id] ?? central.retrievePeripherals(withIdentifiers: [dev.id]).first else {
            state = .failed("设备已不可见，请重新搜索")
            return
        }
        manualDisconnect = false
        attach(p)
    }

    /// 用上次成功连接的设备直接重连（不需要扫描）
    func autoConnectIfSaved() {
        guard case .idle = state, peripheral == nil else { return }
        guard let s = UserDefaults.standard.string(forKey: savedKey),
              let uuid = UUID(uuidString: s) else { return }
        guard central.state == .poweredOn else { return }
        guard let p = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            BtLog.ctrl("上次的控制器 \(s.prefix(8)) 不在系统缓存中，需要重新扫描")
            return
        }
        BtLog.ctrl("按上次的 identifier 直接重连 \(p.name ?? s.prefix(8))")
        manualDisconnect = false
        attach(p)
    }

    private func attach(_ p: CBPeripheral) {
        if let old = peripheral, old.identifier != p.identifier {
            central.cancelPeripheralConnection(old)
        }
        resetSession()
        reconnectAttempts = 0
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        peripheral = p
        p.delegate = self
        connectedName = p.name ?? "智科控制器"
        state = .connecting(connectedName)
        BtLog.ctrl("发起连接 \(connectedName) id=\(String(p.identifier.uuidString.prefix(8)))")
        central.connect(p, options: nil)
    }

    func disconnect() {
        manualDisconnect = true
        stopTimers()
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        resetSession()
        readout = ZhikeReadout()
        connectedName = ""
        state = .idle
        BtLog.ctrl("主动断开控制器")
    }

    private func resetSession() {
        writeChar = nil
        initChar = nil
        notifyChars = []
        pendingServices = []
        allChars = []
        subscribedCount = 0
        sessionStarted = false
        forceResponseWrite = false
        rxCount = 0
        txCount = 0
        txFail = 0
        assembler.reset()
        decoder.reset()
    }

    private func stopTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        watchdog?.invalidate(); watchdog = nil
    }

    // ── 会话：发开启帧 + 轮询 ──

    private func beginSession() {
        guard !sessionStarted, let p = peripheral, let w = writeChar else { return }
        sessionStarted = true
        state = .connected(connectedName)
        BtLog.ctrl("订阅就绪，发送开启帧并进入 200ms 轮询（MTU 由系统协商）")
        write(Self.cmdInit, to: (initChar ?? w), on: p)
        startWatchdog()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self, let pp = self.peripheral, let wc = self.writeChar else { return }
            self.write(Self.cmdPoll, to: wc, on: pp)
        }
        // 无数据 3.5s → 换成「需要应答的写」再试一次（部分模块只认 Write Request）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.readout.valid == false, self.peripheral != nil else { return }
            self.forceResponseWrite = true
            BtLog.ctrl("仍无数据 → 改用需应答的写重试")
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.dataTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard !self.readout.valid else { return }
            BtLog.ctrl("已连接但 \(Int(Self.dataTimeout))s 内无有效帧（写 \(self.txCount) 帧 / 被拒 \(self.txFail) / 通知 \(self.rxCount) 条）")
            self.state = .failed("已连接但收不到控制器数据 · 请稍后重试")
            self.stopTimers()
        }
    }

    private func write(_ bytes: [UInt8], to ch: CBCharacteristic, on p: CBPeripheral) {
        let canNoRsp = ch.properties.contains(.writeWithoutResponse)
        let canRsp = ch.properties.contains(.write)
        guard canNoRsp || canRsp else {
            BtLog.ctrl("写特征不支持写操作：\(ch.uuid.uuidString)")
            return
        }
        let type: CBCharacteristicWriteType =
            (canNoRsp && !forceResponseWrite) ? .withoutResponse : .withResponse
        if type == .withoutResponse, !p.canSendWriteWithoutResponse {
            return                                  // 上一帧还没发完，这一拍跳过
        }
        txCount += 1
        if txCount <= 3 {
            BtLog.ctrl("TX [\(type == .withoutResponse ? "noRsp" : "rsp")] \(BtLog.hex(bytes))")
        }
        p.writeValue(Data(bytes), for: ch, type: type)
    }

    // ── 收数据 ──

    private func handleValue(_ data: Data) {
        let bytes = [UInt8](data)
        if rxCount < 3 {
            BtLog.ctrl("RX len=\(bytes.count) \(BtLog.hex(bytes, maxCount: 24))")
        }
        rxCount += 1
        for frame in assembler.feed(bytes) where decoder.decode(frame) {
            let r = ZhikeReadout(valid: true,
                                 rpm: decoder.rpm,
                                 busVoltageV: decoder.busVoltageV,
                                 busCurrentA: decoder.busCurrentA,
                                 tempC: decoder.controllerTempC,
                                 phaseCurrentA: decoder.phaseCurrentA,
                                 faultBits: decoder.faultBits,
                                 regen: decoder.regen)
            if !readout.valid {
                BtLog.ctrl("收到首帧（转速 \(Int(decoder.rpm))rpm）")
                state = .streaming(connectedName)
                watchdog?.invalidate()
                watchdog = nil
            }
            readout = r
        }
    }

    // ── 重连 ──

    private func scheduleReconnect(_ p: CBPeripheral) {
        reconnectTimer?.invalidate()
        reconnectAttempts += 1
        guard reconnectAttempts <= maxReconnectAttempts else {
            BtLog.ctrl("控制器重连 \(maxReconnectAttempts) 次仍失败")
            state = .failed("控制器已断开，请重新连接")
            return
        }
        state = .reconnecting(connectedName, reconnectAttempts)
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: Self.reconnectDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            BtLog.ctrl("自动重连控制器 第 \(self.reconnectAttempts) 次")
            self.peripheral = p
            p.delegate = self
            self.central.connect(p, options: nil)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension ZhikeService: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantScan { beginScan() }
        case .unauthorized:
            state = .failed("蓝牙权限被拒绝：设置 → 隐私与安全性 → 蓝牙")
        case .poweredOff:
            state = .failed("蓝牙未开启")
        case .unsupported:
            state = .failed("此设备不支持蓝牙")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        if rssi == 127 || rssi == 0 { return }
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        let display = name.isEmpty ? "未命名设备" : name
        let zhike = isZhikeName(name)
        found[peripheral.identifier] = peripheral
        let dev = CtrlDevice(id: peripheral.identifier, name: display, rssi: rssi, isZhike: zhike)
        if let idx = devices.firstIndex(where: { $0.id == dev.id }) {
            // 信号抖动小于 3dB 不刷新，避免每秒几十次无意义的重绘
            if abs(devices[idx].rssi - rssi) < 3 { return }
            devices[idx] = dev
        } else {
            devices.append(dev)
            BtLog.scan("发现 \(display) \(dev.idText) \(rssi)dBm\(zhike ? "（智科）" : "")")
        }
        devices.sort { a, b in
            if a.isZhike != b.isZhike { return a.isZhike }
            return a.rssi > b.rssi
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        BtLog.ctrl("链路已建立，开始发现服务")
        // 先发现服务；iOS 会在完成后再回调，不存在 Android 那种被 MTU 挤掉的问题
        peripheral.delegate = self
        peripheral.discoverServices(nil)
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedKey)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        BtLog.ctrl("连接失败 \(error?.localizedDescription ?? "未知原因")")
        if !manualDisconnect, reconnectAttempts < maxReconnectAttempts {
            scheduleReconnect(peripheral)
            return
        }
        state = .failed("连接失败：\(error?.localizedDescription ?? "未知原因")")
        resetSession()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        stopTimers()
        let wasLive = sessionStarted
        writeChar = nil
        initChar = nil
        notifyChars = []
        sessionStarted = false
        if manualDisconnect {
            manualDisconnect = false
            return
        }
        let reason = error?.localizedDescription ?? "无错误"
        BtLog.ctrl("链路断开（\(reason)），原来\(wasLive ? "已连接" : "未连上")")
        if wasLive {
            scheduleReconnect(peripheral)
        } else {
            state = .idle
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ZhikeService: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            BtLog.ctrl("服务发现失败 \(error.localizedDescription)")
            state = .failed("服务发现失败 · 请重试")
            return
        }
        let services = peripheral.services ?? []
        BtLog.ctrl("服务发现完成，服务数=\(services.count) "
                   + services.map { $0.uuid.uuidString }.joined(separator: ","))
        allChars = []
        pendingServices = services
        requestNextService(peripheral)
    }

    private func requestNextService(_ p: CBPeripheral) {
        guard !pendingServices.isEmpty else {
            finishCharacteristicDiscovery(p)
            return
        }
        let svc = pendingServices.removeFirst()
        p.discoverCharacteristics(nil, for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            BtLog.ctrl("特征发现失败 \(service.uuid.uuidString) \(error.localizedDescription)")
        }
        for c in service.characteristics ?? [] {
            allChars.append(c)
            var props: [String] = []
            if c.properties.contains(.read) { props.append("读") }
            if c.properties.contains(.write) { props.append("写") }
            if c.properties.contains(.writeWithoutResponse) { props.append("无应答写") }
            if c.properties.contains(.notify) { props.append("通知") }
            if c.properties.contains(.indicates) { props.append("指示") }
            BtLog.ctrl("  特征 \(c.uuid.uuidString) [\(props.joined(separator: " "))]")
        }
        requestNextService(peripheral)
    }

    private func finishCharacteristicDiscovery(_ p: CBPeripheral) {
        func writable(_ c: CBCharacteristic) -> Bool {
            c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)
        }
        func notifiable(_ c: CBCharacteristic) -> Bool {
            c.properties.contains(.notify) || c.properties.contains(.indicates)
        }

        let w1 = allChars.first { $0.uuid == Self.ffe1 && writable($0) }
        let w2 = allChars.first { $0.uuid == Self.ffe2 && writable($0) }
        writeChar = w1 ?? w2 ?? allChars.first { writable($0) }
        initChar = w2 ?? writeChar
        // FFE1 优先做通知，其余可通知特征一并订阅（部分固件从 FFE2 回数据）
        var notifies = allChars.filter { notifiable($0) }
        if let idx = notifies.firstIndex(where: { $0.uuid == Self.ffe1 }) {
            let first = notifies.remove(at: idx)
            notifies.insert(first, at: 0)
        }
        notifyChars = notifies

        guard let w = writeChar, !notifyChars.isEmpty else {
            BtLog.ctrl("未找到可用特征，判定非智科设备")
            state = .failed("非智科设备 · 未找到可用特征")
            if let pp = self.peripheral { central.cancelPeripheralConnection(pp) }
            return
        }
        BtLog.ctrl("选用 write=\(w.uuid.uuidString) init=\((initChar ?? w).uuid.uuidString) 可通知特征=\(notifyChars.count)")
        subscribedCount = 0
        for c in notifyChars {
            p.setNotifyValue(true, for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            BtLog.ctrl("订阅失败 \(characteristic.uuid.uuidString) \(error.localizedDescription)")
        }
        if characteristic.isNotifying {
            subscribedCount += 1
            beginSession()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            BtLog.ctrl("读值错误 \(characteristic.uuid.uuidString) \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        handleValue(data)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            txFail += 1
            BtLog.ctrl("写命令失败 \(error.localizedDescription)")
        }
    }
}

// MARK: - 名字识别 / 信号强度

extension ZhikeService {

    static func isZhikeName(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let up = name.uppercased()
        return up.contains("GEKOO") || up.contains("ZHIKE") || name.contains("智科")
    }
}

/// 四格信号柱（阈值与 Android 的 SignalBarView 一致）
struct CtrlSignalBars: View {
    var rssi: Int
    var tint: Color
    var dim: Color

    private var level: Int {
        if rssi >= -55 { return 4 }
        if rssi >= -68 { return 3 }
        if rssi >= -78 { return 2 }
        if rssi >= -90 { return 1 }
        return 0
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i < level ? tint : dim)
                    .frame(width: 3, height: CGFloat(5 + i * 4))
            }
        }
        .frame(height: 20, alignment: .bottom)
    }
}

/// 路径损耗估算距离（仅供相对比较，不做精确测距）
func ctrlDistanceText(rssi: Int) -> String {
    if rssi >= -50 { return "很近" }
    let meters = pow(10.0, Double(-45 - rssi) / 25.0)
    if meters < 1 { return "<1 m" }
    if meters > 30 { return ">30 m" }
    return String(format: "%.0f m", meters)
}
