//
//  KeychainStore.swift
//  Surechigai
//
//  JWTトークンとユーザーUUIDをKeychainに保存する（設計書 5章 / 4.1 Security）。
//

import Foundation
import Security

final class KeychainStore {
    static let shared = KeychainStore()
    private init() {}

    private let service = "com.maedataiki.Surechigai"

    private enum Account {
        static let token = "jwt.token"
        static let uuid  = "user.uuid"
    }

    var token: String? {
        get { read(Account.token) }
        set { write(Account.token, newValue) }
    }

    var uuid: String? {
        get { read(Account.uuid) }
        set { write(Account.uuid, newValue) }
    }

    // MARK: - 低レベル操作

    private func write(_ account: String, _ value: String?) {
        // 既存を削除してから入れ直す（更新も兼ねる）
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let value, let data = value.data(using: .utf8) else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}
