//
//  MainTabView.swift
//  Surechigai
//
//  ログイン後のメインのタブ構成。
//

import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("すれ違い", systemImage: "figure.2.arms.open") }

            MapPinsView()
                .tabItem { Label("マップ", systemImage: "map") }

            ProfileView()
                .tabItem { Label("プロフィール", systemImage: "person.crop.circle") }

            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
    }
}
