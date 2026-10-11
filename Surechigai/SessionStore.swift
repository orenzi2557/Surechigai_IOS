//
//  SessionStore.swift
//  Surechigai
//
//  ログイン状態とログインユーザー情報を保持する。
//

import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {

    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var uuid: String?
    @Published var currentUser: UserResponse?
    /// 自動でログアウトさせた理由（ログイン画面に表示する）。手動ログアウトでは nil。
    @Published var signOutReason: String?

    init() {
        if let token = KeychainStore.shared.token, !token.isEmpty {
            self.uuid = KeychainStore.shared.uuid
            self.isAuthenticated = true
        }
    }

    func signIn(token: String, uuid: String) {
        KeychainStore.shared.token = token
        KeychainStore.shared.uuid = uuid
        self.uuid = uuid
        self.signOutReason = nil
        // アニメーションは RootView 側の .animation(value:) に任せる
        // （モデル内 withAnimation は状態反映が一度反映されない場合があったため外す）
        self.isAuthenticated = true
    }

    func signOut(reason: String? = nil) {
        self.signOutReason = reason
        KeychainStore.shared.token = nil
        KeychainStore.shared.uuid = nil
        self.uuid = nil
        self.currentUser = nil
        self.isAuthenticated = false
    }
}
