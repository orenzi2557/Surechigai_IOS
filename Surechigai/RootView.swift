//
//  RootView.swift
//  Surechigai
//
//  ログイン状態に応じてログイン画面 / メイン画面を出し分ける。
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var encounterSync: EncounterSync
    @EnvironmentObject private var zoneStore: ZoneStore

    var body: some View {
        ZStack {
            if session.isAuthenticated {
                MainTabView()
                    .transition(.opacity)
            } else {
                LoginView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: session.isAuthenticated)
        // アドバタイズにはアカウントUUIDを載せる。受信側はこれを相手UUIDとして扱い
        // サーバーのユーザーと突合するため、ログイン中だけ発信できるようにする。
        // マッチのOn/Off自体は HomeView がサーバーの値に合わせて設定する。
        .onChange(of: session.isAuthenticated, initial: true) { _, isAuthenticated in
            ble.myAccountUUID = isAuthenticated ? session.uuid : nil
            encounterSync.currentUserUUID = isAuthenticated ? session.uuid : nil
            if !isAuthenticated {
                ble.matchEnabled = false
                encounterSync.reset()
            }
        }
        // マッチしない場所を BLE に伝える（範囲内では発信・受信を止める）
        .onReceive(zoneStore.$zones) { zones in
            ble.zones = zones
        }
        // 検知したすれ違いをサーバーへ送る（設計書v3の中核。片方向でマッチがpendingになる）
        .task {
            ble.onDetect = { [weak encounterSync] peer in
                encounterSync?.handle(peer, myUUID: session.uuid)
            }
            // 念のため送信直前にも確認する。検知した地点がマッチしない場所の中なら送らない
            // （裏にいて範囲に入ったことへの反応が遅れた間に拾った分など）
            encounterSync.shouldDrop = { [weak zoneStore] peer in
                guard let lat = peer.latitude, let lon = peer.longitude,
                      let zone = zoneStore?.zone(containingLatitude: lat, longitude: lon) else { return nil }
                return "マッチしない場所「\(zone.name)」で検知"
            }
            // トークンが通らなくなったら（期限切れ・別端末で退会など）ログイン画面に戻す
            api.onUnauthorized = { [weak session] in
                guard let session, session.isAuthenticated else { return }
                session.signOut(reason: "ログインの有効期限が切れたか、アカウントが無効になりました。もう一度ログインしてください。")
            }
        }
    }
}
