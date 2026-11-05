// Xloc — WiFiBridge.swift
// Wi-Fi 指纹伪造。这是 Xloc 相对 Andromeda 最关键的功能补齐。
//
// 为什么必须做：
//   现在主流 App 判断"是否改定位"的第一道防线不是 GPS，而是交叉校验：
//   GPS 说在纽约，但当前 Wi-Fi 的 BSSID 在数据库里注册在北京 → 直接判定伪造。
//   这一步做不到，GPS 与网络指纹就会互相矛盾。
//
// 实现分三层：
//   1. 读取真实网络（CNCopyCurrentNetworkInfo / 私有 WiFiManager）→ 作为模板
//   2. 写入伪造值（SCDynamicStore 优先；失败则回退到 plist 补丁）
//   3. 备份 + 一键还原（必须！否则重启后网络状态可能异常）
//
// ⚠️ 风险：直接改 SystemConfiguration 属于系统级操作。Xloc 默认 dry-run，
//    必须显式开启 applyRealChanges 才会真正写入，且退出/停止时自动还原。

import Foundation
import SystemConfiguration
import SystemConfiguration.CaptiveNetwork
import CoreLocation

// MARK: - 模型

public struct WiFiProfile: Codable, Equatable, Sendable {
    public var ssid: String
    public var bssid: String        // "aa:bb:cc:dd:ee:ff"
    public var rssi: Int            // dBm，典型 -30 ~ -90
    public var channel: Int         // 1~165
    public var security: String     // "WPA2" / "WPA3" / "WEP" / "Open"
    public var isHidden: Bool

    public init(ssid: String, bssid: String, rssi: Int = -55,
                channel: Int = 6, security: String = "WPA2", isHidden: Bool = false) {
        self.ssid = ssid
        self.bssid = bssid.uppercased()
        self.rssi = rssi
        self.channel = channel
        self.security = security
        self.isHidden = isHidden
    }

    /// 常见家用/商用路由器的默认 SSID 前缀，用于"看起来合理"的随机生成
    public static let plausibleSSIDPrefixes = [
        "TP-LINK_", "Xiaomi_", "HUAWEI-", "ChinaNet-", "CMCC-", "CU_",
        "MERCURY_", "Tenda_", "H3C_", "Redmi_", "iPhone", "DIRECT-"
    ]
}

// MARK: - BSSID 校验

public enum BSSIDValidator {
    public struct Result: Sendable {
        public var isValid: Bool
        public var problems: [String]
        public var vendorHint: String?
    }

    /// 常见 OUI 抽样（用于"这个 BSSID 像不像该地区的路由器"的粗略提示）
    private static let knownOUI: [String: String] = [
        "A4:2B:B0": "TP-Link", "50:C7:BF": "TP-Link", "C0:25:E9": "TP-Link",
        "F8:FF:C2": "Apple",   "3C:2E:FF": "Apple",  "A8:5C:2C": "Apple",
        "64:09:80": "Xiaomi",  "78:11:DC": "Xiaomi", "50:8F:4C": "Xiaomi",
        "48:7B:6B": "Huawei",  "E0:19:1D": "Huawei", "70:72:3C": "Huawei",
        "34:96:72": "H3C",     "00:0F:E2": "H3C",    "70:BA:EF": "H3C",
        "00:1A:2B": "Cisco",   "00:1B:D4": "Cisco"
    ]

    public static func validate(_ bssid: String) -> Result {
        var problems: [String] = []
        let parts = bssid.split(separator: ":").map(String.init)
        guard parts.count == 6 else {
            return Result(isValid: false, problems: ["格式必须是 aa:bb:cc:dd:ee:ff"], vendorHint: nil)
        }
        var bytes: [UInt8] = []
        for p in parts {
            guard p.count == 2, let b = UInt8(p, radix: 16) else {
                return Result(isValid: false, problems: ["含有非十六进制字符"], vendorHint: nil)
            }
            bytes.append(b)
        }
        if bytes.allSatisfy({ $0 == 0 }) { problems.append("全 0 地址，一眼假") }
        if bytes == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] { problems.append("广播地址，非法") }
        if bytes[0] & 0x01 == 1 { problems.append("组播位为 1，真实 AP 不会这样") }
        if bytes[0] & 0x02 == 2 { problems.append("本地管理位为 1（LAA），像伪造的 MAC") }

        let oui = parts.prefix(3).joined(separator: ":").uppercased()
        return Result(isValid: problems.isEmpty, problems: problems,
                      vendorHint: knownOUI[oui])
    }

    /// 生成一个"看起来像真机"的 BSSID（使用真实厂商 OUI）
    public static func randomPlausible(seed: inout SeededRandom) -> String {
        let ouis = Array(knownOUI.keys).sorted()
        let oui = ouis[Int(seed.next() % UInt64(ouis.count))]
        var bytes = oui.split(separator: ":").map { UInt8($0, radix: 16) ?? 0 }
        for _ in 0..<3 { bytes.append(UInt8(seed.next() % 254) + 1) }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

// MARK: - 桥

public final class WiFiBridge {
    public static let shared = WiFiBridge()

    /// 真正写入系统（默认关闭，先 dry-run 看日志）
    public var applyRealChanges = false
    /// 退出时自动还原
    public var autoRestore = true

    private let wifiPlistPath = "/private/var/preferences/SystemConfiguration/com.apple.wifi.plist"
    private var backupPath: String?
    private var applied = false
    private var dynamicStore: SCDynamicStore?

    public private(set) var currentProfile: WiFiProfile?

    private init() {}

    // MARK: 读取真实网络

    /// 读取当前连接的 Wi-Fi（需要 com.apple.developer.networking.wifi-info 权限）
    public func readCurrentNetwork() -> WiFiProfile? {
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return nil }
        for name in interfaces {
            guard let info = CNCopyCurrentNetworkInfo(name as CFString) as? [String: Any] else { continue }
            guard let ssid = info[kCNNetworkInfoKeySSID as String] as? String else { continue }
            let bssid = info[kCNNetworkInfoKeyBSSID as String] as? String ?? ""
            let p = WiFiProfile(ssid: ssid, bssid: bssid)
            currentProfile = p
            return p
        }
        return nil
    }

    // MARK: 应用伪造

    public struct ApplyResult: Sendable {
        public var success: Bool
        public var method: String
        public var messages: [String]
    }

    @discardableResult
    public func apply(_ profile: WiFiProfile) -> ApplyResult {
        var msgs: [String] = []

        let check = BSSIDValidator.validate(profile.bssid)
        if !check.isValid { msgs.append(contentsOf: check.problems) }
        if let v = check.vendorHint { msgs.append("OUI 识别为 \(v)") }

        guard applyRealChanges else {
            msgs.append("dry-run：未写入系统（打开 applyRealChanges 后生效）")
            return ApplyResult(success: true, method: "dry-run", messages: msgs)
        }

        // 1) 备份
        if backupPath == nil {
            let dst = NSTemporaryDirectory() + "xloc-wifi-backup-\(Int(Date().timeIntervalSince1970)).plist"
            if FileManager.default.fileExists(atPath: wifiPlistPath) {
                try? FileManager.default.copyItem(atPath: wifiPlistPath, toPath: dst)
                backupPath = dst
                msgs.append("已备份 → \(dst)")
            }
        }

        // 2) SCDynamicStore（首选，改动即时生效且可回滚）
        if applyViaDynamicStore(profile) {
            applied = true
            return ApplyResult(success: true, method: "SCDynamicStore", messages: msgs + ["已写入 State:/Network/Interface/en0/AirPort"])
        }

        // 3) plist 回退
        if applyViaPlist(profile) {
            applied = true
            return ApplyResult(success: true, method: "plist", messages: msgs + ["已写入 \(wifiPlistPath)"])
        }

        msgs.append("两种方式都失败：检查 no-sandbox 与 SCDynamicStore-write-access 权限")
        return ApplyResult(success: false, method: "none", messages: msgs)
    }

    public func restore() {
        guard applied else { return }
        if let backup = backupPath, FileManager.default.fileExists(atPath: backup) {
            try? FileManager.default.removeItem(atPath: wifiPlistPath)
            try? FileManager.default.copyItem(atPath: backup, toPath: wifiPlistPath)
        }
        if let store = dynamicStore {
            SCDynamicStoreRemoveValue(store, "State:/Network/Interface/en0/AirPort" as CFString)
        }
        applied = false
        backupPath = nil
    }

    // MARK: 实现

    private func applyViaDynamicStore(_ p: WiFiProfile) -> Bool {
        if dynamicStore == nil {
            var ctx = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
            dynamicStore = SCDynamicStoreCreate(nil, "Xloc" as CFString, nil, &ctx)
        }
        guard let store = dynamicStore else { return false }

        let payload: [String: Any] = [
            "SSID": Data(p.ssid.utf8),
            "SSID_STR": p.ssid,
            "BSSID": p.bssid,
            "RSSI": p.rssi,
            "Channel": p.channel,
            "SecurityType": p.security,
            "Hidden": p.isHidden
        ]
        let ok = SCDynamicStoreSetValue(store, "State:/Network/Interface/en0/AirPort" as CFString,
                                        payload as CFDictionary)
        if ok { SCDynamicStoreNotifyValue(store, "State:/Network/Interface/en0/AirPort" as CFString) }
        return ok
    }

    private func applyViaPlist(_ p: WiFiProfile) -> Bool {
        guard var root = NSDictionary(contentsOfFile: wifiPlistPath) as? [String: Any] else {
            return false
        }
        // 结构随 iOS 版本变化，这里只做保守的"当前网络"字段覆盖，
        // 找不到目标键时不做破坏性写入。
        var changed = false
        if var networks = root["KnownNetworks"] as? [String: Any] {
            for (k, v) in networks {
                guard var entry = v as? [String: Any] else { continue }
                if (entry["SSID_STR"] as? String) == p.ssid || k == p.bssid {
                    entry["SSID_STR"] = p.ssid
                    entry["BSSID"] = p.bssid
                    entry["RSSI"] = p.rssi
                    networks[k] = entry
                    changed = true
                }
            }
            if changed { root["KnownNetworks"] = networks }
        }
        guard changed else { return false }
        return (root as NSDictionary).write(toFile: wifiPlistPath, atomically: true)
    }
}
