// Xloc — DeviceIdentity.swift
// 设备标识（UID）。
//
// 要求：同一台设备，无论卸载重装多少次，UID 都不变。
//
// Keychain 在 TrollStore 应用里不可靠：fakesign 的 App 通常没有
// application-identifier / keychain-access-groups，SecItemAdd 会返回 -34018
// （errSecMissingEntitlement），结果就是每次启动都生成一个新 ID。
//
// 所以主存储放在 App 容器之外：
//     /var/mobile/Library/Preferences/com.onshine.xloc.uid.plist
// 卸载 App 不会删除这个文件（它不属于任何 App 容器），只有抹机才会没。
//
// 读取顺序：文件 → Keychain（旧版本遗留）→ UserDefaults，全都没有才生成。

import Foundation
import Security

enum DeviceIdentity {
    private static let filePath = "/var/mobile/Library/Preferences/com.onshine.xloc.uid.plist"
    private static let defaultsKey = "xloc.device.uid"
    private static let keychainService = "com.onshine.xloc.identity"
    private static let keychainAccount = "device-uid"

    private static var cached: String?

    /// 完整 UID（32 位十六进制）
    static var uid: String {
        if let c = cached { return c }

        if let v = readFile() ?? readKeychain() ?? readDefaults(), isValid(v) {
            cached = v
            // 顺手补齐其它几处，方便以后迁移
            saveFile(v)
            return v
        }

        let v = generate()
        cached = v
        saveFile(v)
        saveDefaults(v)
        saveKeychain(v)
        return v
    }

    /// 短 UID，方便口头报障
    static var shortUID: String { String(uid.prefix(8)) }

    /// 分组展示
    static var prettyUID: String {
        let s = uid
        guard s.count == 32 else { return s }
        let a = s.index(s.startIndex, offsetBy: 8)
        let b = s.index(s.startIndex, offsetBy: 16)
        let c = s.index(s.startIndex, offsetBy: 24)
        return "\(s[..<a])-\(s[a..<b])-\(s[b..<c])-\(s[c...])"
    }

    /// UID 是否真的落盘了（设置页用来提示）
    static var isPersisted: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }

    static var storagePath: String { filePath }

    // MARK: - 生成

    private static func generate() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func isValid(_ s: String) -> Bool {
        s.count >= 16 && s.allSatisfy { $0.isHexDigit }
    }

    // MARK: - 文件（主存储）

    private static func readFile() -> String? {
        guard let dict = NSDictionary(contentsOfFile: filePath) as? [String: Any],
              let value = dict["uid"] as? String else { return nil }
        return value
    }

    private static func saveFile(_ value: String) {
        let dict: [String: Any] = [
            "uid": value,
            "created": Date().timeIntervalSince1970
        ]
        let ok = (dict as NSDictionary).write(toFile: filePath, atomically: true)
        if !ok {
            // 权限不足时退到容器内（重装会丢，但至少本次运行稳定）
            let fallback = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("device-uid.plist")
            (dict as NSDictionary).write(to: fallback, atomically: true)
        }
    }

    // MARK: - UserDefaults

    private static func readDefaults() -> String? {
        UserDefaults.standard.string(forKey: defaultsKey)
    }

    private static func saveDefaults(_ value: String) {
        UserDefaults.standard.set(value, forKey: defaultsKey)
    }

    // MARK: - Keychain（能写就写，失败无所谓）

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func saveKeychain(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
