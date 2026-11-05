// Xloc — WiFiScreen.swift
// Wi-Fi 指纹伪造：编辑、校验、应用、还原。

import SwiftUI

struct WiFiScreen: View {
    @EnvironmentObject var engine: SimulationEngine

    @State private var ssid = ""
    @State private var bssid = ""
    @State private var rssi: Double = -55
    @State private var channel: Double = 6
    @State private var security = "WPA2"
    @State private var validation: BSSIDValidator.Result?
    @State private var current: WiFiProfile?
    @State private var log: [String] = []

    private let securities = ["WPA2", "WPA3", "WEP", "Open"]

    var body: some View {
        NavigationView {
            Form {
                Section("当前网络") {
                    if let c = current {
                        HStack { Text("SSID"); Spacer(); Text(c.ssid).foregroundStyle(.secondary) }
                        HStack { Text("BSSID"); Spacer(); Text(c.bssid.isEmpty ? "（系统未提供）" : c.bssid).foregroundStyle(.secondary) }
                    } else {
                        Text("读不到当前 Wi-Fi（未连接或缺少 wifi-info 权限）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("以当前网络为模板") {
                        if let c = current {
                            ssid = c.ssid; bssid = c.bssid
                            validate()
                        }
                    }
                    .disabled(current == nil)
                }

                Section("伪造目标") {
                    TextField("SSID", text: $ssid)
                    TextField("BSSID（aa:bb:cc:dd:ee:ff）", text: $bssid)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: bssid) { _ in validate() }

                    if let v = validation {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(v.isValid ? "格式合法" : "格式有问题",
                                  systemImage: v.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(v.isValid ? .green : .orange)
                                .font(.caption)
                            ForEach(v.problems, id: \.self) { p in
                                Text("· \(p)").font(.caption2).foregroundStyle(.secondary)
                            }
                            if let vendor = v.vendorHint {
                                Text("OUI 厂商：\(vendor)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button("生成一个合理的 BSSID") {
                        var rng = SeededRandom(seed: UInt64(Date().timeIntervalSince1970))
                        bssid = BSSIDValidator.randomPlausible(seed: &rng)
                        validate()
                    }

                    VStack(alignment: .leading) {
                        Text("信号强度：\(Int(rssi)) dBm").font(.subheadline)
                        Slider(value: $rssi, in: -95 ... -30, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("信道：\(Int(channel))").font(.subheadline)
                        Slider(value: $channel, in: 1...165, step: 1)
                    }
                    Picker("加密方式", selection: $security) {
                        ForEach(securities, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section {
                    Button("应用到模拟") {
                        let p = WiFiProfile(ssid: ssid, bssid: bssid, rssi: Int(rssi),
                                            channel: Int(channel), security: security)
                        engine.wifiProfile = p
                        engine.wifiEnabled = true
                        let r = WiFiBridge.shared.apply(p)
                        log = ["[\(r.method)] " + (r.success ? "成功" : "失败")] + r.messages
                    }
                    .disabled(!(validation?.isValid ?? false))

                    Button("还原系统 Wi-Fi 配置", role: .destructive) {
                        WiFiBridge.shared.restore()
                        engine.wifiEnabled = false
                        log = ["已还原"]
                    }
                } footer: {
                    Text("默认 dry-run，不会改系统。要真正生效需在设置里打开「真正写入系统」。停止模拟时会自动还原。")
                }

                if !log.isEmpty {
                    Section("日志") {
                        ForEach(log, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }
            }
            .navigationTitle("Wi-Fi")
            .onAppear {
                current = WiFiBridge.shared.readCurrentNetwork()
                if let p = engine.wifiProfile {
                    ssid = p.ssid; bssid = p.bssid
                    rssi = Double(p.rssi); channel = Double(p.channel); security = p.security
                    validate()
                }
            }
        }
    }

    private func validate() {
        validation = BSSIDValidator.validate(bssid)
    }
}
