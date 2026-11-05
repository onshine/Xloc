// Xloc — DeviceIdentity.swift
// 设备标识（UID）。
//
// 用 Keychain 存一个随机 UUID：
//   - 每台设备唯一
//   - 卸载重装不变（Keychain 不随 App 删除而清空）
//   - 不依赖 IDFA/IDFV，不涉及广告追踪

import Foundation
import Security

enum DeviceIdentity {
    private static let service = "com.onshine.xloc.identity"
    private static let account = "device-uid"

    /// 完整 UID（32 位十六进制）
    static var uid: String {
        if let existing = read() { return existing }
        let value = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        save(value)
        return value
    }

    /// 短 UID，方便口头报障
    static var shortUID: String { String(uid.prefix(8)) }

    /// 带分隔符的展示形式
    static var prettyUID: String {
        let s = uid
        guard s.count == 32 else { return s }
        let idx = s.index(s.startIndex, offsetBy: 8)
        let idx2 = s.index(s.startIndex, offsetBy: 16)
        let idx3 = s.index(s.startIndex, offsetBy: 24)
        return "\(s[..<idx])-\(s[idx..<idx2])-\(s[idx2..<idx3])-\(s[idx3...])"
    }

    // MARK: - Keychain

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func save(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
