import Foundation
import SwiftUI

struct ConnectSheet: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var service: BmsService
    @Environment(\.dismiss) private var dismiss

    @State private var vendor: BatteryVendor = .jikong

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("厂家", selection: $vendor) {
                        ForEach(BatteryVendor.allCases) { v in
                            Text(v.label).tag(v)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("显示全部蓝牙设备", isOn: $service.showAllDevices)
                } footer: {
                    Text("默认只显示带 FFE0 服务的设备；列表里找不到时打开上面的开关再搜。")
                }

                Section("设备") {
                    if service.devices.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(service.state.isBusy ? "正在搜索…" : "暂无设备")
                                .foregroundColor(.secondary)
                        }
                    }
                    ForEach(service.devices) { dev in
                        Button {
                            service.connect(dev)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dev.name)
                                        .foregroundColor(.primary)
                                    Text(dev.id.uuidString.prefix(8))
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("\(dev.rssi) dBm")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                Section {
                    Button {
                        service.startDemo(vendor: vendor)
                        dismiss()
                    } label: {
                        Label("进入演示模式（无需保护板）", systemImage: "play.circle")
                    }
                    if service.state.isLive || service.state == .idle {
                        Button(role: .destructive) {
                            service.disconnect()
                        } label: {
                            Label("断开连接", systemImage: "wifi.slash")
                        }
                    }
                } footer: {
                    Text(service.state.text)
                }
            }
            .navigationTitle("连接保护板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        service.startScan(vendor: vendor)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                vendor = settings.vendor
                service.startScan(vendor: vendor)
            }
            .onChange(of: vendor) { v in
                settings.vendor = v
                service.startScan(vendor: v)
            }
            .onDisappear {
                if !service.state.isLive { service.stopScan() }
            }
        }
    }
}
