//
//  AppSettings.swift
//  Surechigai
//
//  サーバー接続まわりの設定。UserDefaults に永続化する。
//

import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {

    /// 開発サーバーのIPアドレス、または https://〜 のURL（モックOFF時に使用）
    @Published var serverIP: String {
        didSet { UserDefaults.standard.set(serverIP, forKey: Keys.serverIP) }
    }

    /// モックモード（サーバー不要）。デフォルト true。
    @Published var useMock: Bool {
        didSet { UserDefaults.standard.set(useMock, forKey: Keys.useMock) }
    }

    /// サーバーのポート（FastAPI想定）
    @Published var serverPort: String {
        didSet { UserDefaults.standard.set(serverPort, forKey: Keys.serverPort) }
    }

    init() {
        let defaults = UserDefaults.standard
        self.serverIP = defaults.string(forKey: Keys.serverIP) ?? "127.0.0.1"
        self.serverPort = defaults.string(forKey: Keys.serverPort) ?? "8000"
        // 初回起動（キー未設定）は true をデフォルトにする
        if defaults.object(forKey: Keys.useMock) == nil {
            self.useMock = true
        } else {
            self.useMock = defaults.bool(forKey: Keys.useMock)
        }
    }

    /// 接続先のベースURL。
    /// ・IPやホスト名だけ（例 10.16.4.8）→ http://10.16.4.8:8000（ローカル開発）
    /// ・URLをそのまま入力（例 https://api.example.com）→ そのまま使う（デプロイ先。ポートは付けない）
    var baseURLString: String {
        let input = serverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if usesFullURL {
            return input.hasSuffix("/") ? String(input.dropLast()) : input
        }
        return "http://\(input):\(serverPort)"
    }

    /// サーバー欄に http(s):// から始まるURLが入っているか（このときポート欄は使わない）
    var usesFullURL: Bool {
        let input = serverIP.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return input.hasPrefix("http://") || input.hasPrefix("https://")
    }

    private enum Keys {
        static let serverIP = "settings.serverIP"
        static let serverPort = "settings.serverPort"
        static let useMock = "settings.useMock"
    }
}
