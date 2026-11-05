// Xloc — AppPatcher.swift
// B 方案：把插件注入到目标 App 的包里，生成一个可安装的 .tipa。
//
// 流程：
//   1. 复制目标 App 的 bundle 到临时目录
//   2. 放入 XlocPlugin.dylib 和 XlocConfig.plist
//   3. 往主程序 Mach-O 头里插一条 LC_LOAD_DYLIB
//   4. 删掉旧的 _CodeSignature（签名必然失效）
//   5. 打包成 Payload/<App>.app 的 .tipa
//
// 产物交给 TrollStore 覆盖安装 —— 由 TrollStore 重新签名，
// 所以不需要在设备上实现 ct_bypass 之类的东西。

import Foundation
import UIKit

struct InstalledApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let path: String
    let isSystem: Bool

    var id: String { bundleID }

    var icon: UIImage? {
        UIImage(named: "AppIcon60x60")  // 占位，列表里用 SF Symbol 兜底
    }
}

enum AppInventory {

    /// 通过 LSApplicationWorkspace 枚举已安装 App（需要 canmaplsdatabase 权限）
    static func installed() -> [InstalledApp] {
        guard let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("defaultWorkspace")),
              let wsAny = cls.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue(),
              let workspace = wsAny as? NSObject,
              workspace.responds(to: NSSelectorFromString("allInstalledApplications")),
              let list = workspace.perform(NSSelectorFromString("allInstalledApplications"))?
                .takeUnretainedValue() as? [NSObject] else {
            return []
        }

        var result: [InstalledApp] = []
        for proxy in list {
            let bundleID = (proxy.value(forKey: "applicationIdentifier") as? String) ?? ""
            guard !bundleID.isEmpty else { continue }
            let name = (proxy.value(forKey: "localizedName") as? String) ?? bundleID
            let url = proxy.value(forKey: "bundleURL") as? URL
            let type = (proxy.value(forKey: "applicationType") as? String) ?? "User"
            guard let path = url?.path else { continue }
            guard path.contains("/Bundle/Application/") else { continue }
            if bundleID.hasPrefix("com.onshine.xloc") { continue }
            result.append(InstalledApp(bundleID: bundleID, name: name,
                                       path: path, isSystem: type != "User"))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum PatchError: LocalizedError {
    case noExecutable
    case noPlugin
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .noExecutable: return "找不到目标 App 的主程序"
        case .noPlugin: return "安装包里缺少 XlocPlugin.dylib"
        case .copyFailed(let s): return "复制失败：\(s)"
        }
    }
}

struct PatchConfig {
    var coordinate: GeoCoordinate
    var altitude: Double = 0
    var accuracy: Double = 5
    var wifi: WiFiProfile?
}

enum AppPatcher {

    /// 生成注入了插件的 .tipa，返回文件位置
    static func makeTipa(app: InstalledApp,
                         config: PatchConfig,
                         progress: @escaping (String) -> Void) throws -> URL {

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("XlocPatch-\(UUID().uuidString)")
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        let appCopy = payload.appendingPathComponent((app.path as NSString).lastPathComponent,
                                                     isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1) 复制 bundle
        progress("复制 App…")
        do {
            try fm.copyItem(at: URL(fileURLWithPath: app.path), to: appCopy)
        } catch {
            throw PatchError.copyFailed(error.localizedDescription)
        }

        // 2) 插件
        progress("放入插件…")
        guard let plugin = Bundle.main.url(forResource: "XlocPlugin", withExtension: "dylib") else {
            throw PatchError.noPlugin
        }
        let pluginDest = appCopy.appendingPathComponent("XlocPlugin.dylib")
        try? fm.removeItem(at: pluginDest)
        try fm.copyItem(at: plugin, to: pluginDest)

        // 3) 配置
        var dict: [String: Any] = [
            "enabled": true,
            "latitude": config.coordinate.latitude,
            "longitude": config.coordinate.longitude,
            "altitude": config.altitude,
            "accuracy": config.accuracy
        ]
        if let wifi = config.wifi {
            dict["ssid"] = wifi.ssid
            dict["bssid"] = wifi.bssid
        }
        (dict as NSDictionary).write(to: appCopy.appendingPathComponent("XlocConfig.plist"), atomically: true)

        // 4) 主程序
        let info = NSDictionary(contentsOf: appCopy.appendingPathComponent("Info.plist")) as? [String: Any]
        guard let execName = info?["CFBundleExecutable"] as? String else {
            throw PatchError.noExecutable
        }
        let exec = appCopy.appendingPathComponent(execName)

        progress("插入加载命令…")
        try MachOInjector.insertDylib(at: exec, path: "XlocPlugin.dylib")

        // 5) 旧签名必然失效
        try? fm.removeItem(at: appCopy.appendingPathComponent("_CodeSignature"))
        try? fm.removeItem(at: appCopy.appendingPathComponent("SC_Info"))

        // 6) 打包
        progress("打包 .tipa…")
        let out = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Xloc-\(app.bundleID).tipa")
        try ZipWriter.zip(folder: work, to: out)

        progress("完成")
        return out
    }
}
