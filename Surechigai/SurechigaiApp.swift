//
//  SurechigaiApp.swift
//  Surechigai
//
//  アプリのエントリポイント。共有オブジェクトを生成して環境に注入する。
//

import SwiftUI

@main
struct SurechigaiApp: App {

    @StateObject private var settings: AppSettings
    @StateObject private var api: APIClient
    @StateObject private var session = SessionStore()
    @StateObject private var ble = BLEManager()
    @StateObject private var encounterSync: EncounterSync
    @StateObject private var zoneStore = ZoneStore()

    init() {
        // settings と api は同じ AppSettings インスタンスを共有させる
        let settings = AppSettings()
        let api = APIClient(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _api = StateObject(wrappedValue: api)
        _encounterSync = StateObject(wrappedValue: EncounterSync(api: api))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(api)
                .environmentObject(session)
                .environmentObject(ble)
                .environmentObject(encounterSync)
                .environmentObject(zoneStore)
                .tint(Color.brandPrimary)
                // このアプリは明るい配色で固定デザインのため、端末がダークモードでも
                // ライト表示に統一する（白背景に白文字で消える問題を防ぐ）。
                .preferredColorScheme(.light)
        }
    }
}
