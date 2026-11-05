// Xloc — Diagnostics.swift
// 自检面板：告诉你"这次模拟在别人眼里长什么样"。
//
// 这是同类工具普遍缺失的部分：
// 大多数用户不知道自己的模拟为什么被发现，只能猜。
// Xloc 把可观测的检测向量全部摊开：权限、模拟标记、Wi-Fi 一致性、环境异常。

import Foundation
import CoreLocation
import SystemConfiguration
import CFNetwork
import UIKit

public struct DiagnosticItem: Identifiable, Sendable {
    public enum Level: String, Sendable {
        case ok, warn, fail, info
    }
    public let id = UUID()
    public var title: String
    public var detail: String
    public var level: Level

    public init(_ title: String, _ detail: String, _ level: Level) {
        self.title = title
        self.detail = detail
        self.level = level
    }
}

public final class Diagnostics {

    // MARK: - 权限

    public static func hasEntitlement(_ key: String) -> Bool {
        return XLHasEntitlement(key as CFString)
    }

    public static func entitlementReport() -> [DiagnosticItem] {
        let required: [(String, String)] = [
            ("com.apple.locationd.simulation", "定位模拟核心权限"),
            ("com.apple.private.security.no-sandbox", "访问系统配置"),
            ("platform-application", "TrollStore 平台应用"),
        ]
        let optional: [(String, String)] = [
            ("com.apple.SystemConfiguration.SCDynamicStore-write-access", "Wi-Fi 指纹写入"),
            ("com.apple.developer.networking.wifi-info", "读取真实 SSID/BSSID"),
            ("com.apple.private.coreservices.canmaplsdatabase", "读取已安装 App 列表"),
        ]
        var out: [DiagnosticItem] = []
        for (k, desc) in required {
            out.append(DiagnosticItem(k, desc, hasEntitlement(k) ? .ok : .fail))
        }
        for (k, desc) in optional {
            out.append(DiagnosticItem(k, desc, hasEntitlement(k) ? .ok : .warn))
        }
        return out
    }

    // MARK: - 模拟标记

    /// 读取系统当前交付给我们的定位，检查它是否被打上"软件模拟"标记。
    /// 这是 App 最容易拿到、也最致命的检测向量。
    public static func checkDeliveredLocation(_ location: CLLocation?) -> DiagnosticItem {
        guard let loc = location else {
            return DiagnosticItem("模拟标记", "还没有收到定位样本", .info)
        }
        if #available(iOS 15.0, *) {
            guard let src = loc.sourceInformation else {
                return DiagnosticItem("模拟标记", "sourceInformation 为 nil（通常是真实定位）", .ok)
            }
            if src.isSimulatedBySoftware {
                return DiagnosticItem("模拟标记",
                                      "isSimulatedBySoftware = true —— 目标 App 一读就知道是模拟",
                                      .fail)
            }
            if src.isProducedByAccessory {
                return DiagnosticItem("模拟标记", "isProducedByAccessory = true（外接设备）", .warn)
            }
            return DiagnosticItem("模拟标记", "未被标记为模拟", .ok)
        }
        return DiagnosticItem("模拟标记", "iOS 15 以下无 sourceInformation", .info)
    }

    // MARK: - 环境

    public static func environmentReport() -> [DiagnosticItem] {
        var out: [DiagnosticItem] = []

        // 越狱痕迹（目标 App 也会做同样的检查）
        let jbPaths = ["/var/lib/cydia", "/var/lib/dpkg", "/usr/lib/systemhook.dylib",
                       "/Library/MobileSubstrate", "/usr/sbin/frida-server"]
        let found = jbPaths.filter { FileManager.default.fileExists(atPath: $0) }
        out.append(DiagnosticItem("越狱痕迹",
                                  found.isEmpty ? "未发现" : "发现：" + found.joined(separator: ", "),
                                  found.isEmpty ? .ok : .warn))

        // 代理
        if let proxy = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] {
            let httpOn = proxy["HTTPEnable"] as? Int ?? 0
            let httpsOn = proxy["HTTPSEnable"] as? Int ?? 0
            out.append(DiagnosticItem("系统代理",
                                      (httpOn == 1 || httpsOn == 1) ? "已开启（可能被风控关注）" : "未开启",
                                      (httpOn == 1 || httpsOn == 1) ? .warn : .ok))
        }

        // VPN / utun
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        var vpn = false
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = p {
                let name = String(cString: cur.pointee.ifa_name)
                if name.hasPrefix("utun") || name.hasPrefix("ppp") { vpn = true }
                p = cur.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        out.append(DiagnosticItem("VPN 接口", vpn ? "存在 utun/ppp（出口 IP 可能不符）" : "未发现",
                                  vpn ? .warn : .ok))

        // 时区一致性（简单版：设备时区 vs 坐标所在经度）
        out.append(DiagnosticItem("时区同步",
                                  "模拟后会自动发送 AutomaticTimeZoneUpdateNeeded",
                                  .info))
        return out
    }

    // MARK: - 一致性

    /// 坐标 vs Wi-Fi 的一致性提示（需要外部提供目标地点的粗略位置）
    public static func wifiConsistency(profile: WiFiProfile?, target: GeoCoordinate?) -> DiagnosticItem {
        guard let profile else {
            return DiagnosticItem("Wi-Fi 一致性", "未设置伪造 Wi-Fi（多数风控会查这一项）", .warn)
        }
        let v = BSSIDValidator.validate(profile.bssid)
        if !v.isValid {
            return DiagnosticItem("Wi-Fi 一致性", "BSSID 不合法：" + v.problems.joined(separator: "；"), .fail)
        }
        if let vendor = v.vendorHint {
            return DiagnosticItem("Wi-Fi 一致性", "SSID/BSSID 已设置，OUI=\(vendor)", .ok)
        }
        return DiagnosticItem("Wi-Fi 一致性", "SSID/BSSID 已设置（OUI 未知厂商）", .warn)
    }

    public static func fullReport(location: CLLocation?,
                                  wifi: WiFiProfile?,
                                  target: GeoCoordinate?) -> [DiagnosticItem] {
        entitlementReport()
            + [checkDeliveredLocation(location), wifiConsistency(profile: wifi, target: target)]
            + environmentReport()
    }
}
