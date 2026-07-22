// KeychainHelper.swift
// 轻量 Keychain 封装：用于持久化登录身份，使其在「删除 App / 重装」后仍保留。
//
// 关键语义：使用 kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly ——
//   ✅ 同一台设备删除 App 再重装：Keychain 仍保留（iOS 不会随 App 删除清空 Keychain）。
//   ❌ 不随 iCloud / iTunes 备份迁移到新设备（更安全，也避免身份被备份导出）。
// 因此：换手机需要重新登录（微信真实环境用 unionid 可跨设备；手机号/Apple 本身跨设备稳定）。
import Foundation
import Security

enum KeychainHelper {
    /// 统一 service 名，避免与其它 App 冲突。
    static let service = "com.aia.auth"

    // MARK: - 身份字段 key
    static let kUserId   = "userId"
    static let kProvider = "provider"
    static let kPhone    = "phone"
    static let kName     = "name"
    /// 微信稳定匿名 id：首次微信登录生成，之后复用（真实环境应改为后端 unionid）。
    static let kWxStable = "wx_stable_id"

    /// 写入字符串（幂等：先删后写）。
    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    /// 读取字符串；不存在返回 nil。
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除指定 key。
    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 清空本 service 下全部身份字段（注销时调用）。
    static func clearAll() {
        for key in [kUserId, kProvider, kPhone, kName, kWxStable] {
            delete(key)
        }
    }
}
