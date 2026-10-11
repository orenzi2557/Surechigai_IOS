//
//  SettingsView.swift
//  Surechigai
//
//  設定画面。サーバー設定・モックトグル・開発者画面・ログアウト・アカウント削除。
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var zoneStore: ZoneStore

    @State private var healthResult: String?
    @State private var isChecking = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    serverCard
                    connectionCard
                    zonesCard
                    privacyCard
                    developerCard
                    logoutButton
                    deleteAccountButton
                }
                .padding(20)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "アカウントを削除しますか？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("削除する", role: .destructive) {
                    Task { await deleteAccount() }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("プロフィール・画像・すれ違い・マッチ・ブロック・投稿したピンがすべて削除され、元に戻せません。")
            }
        }
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "サーバー設定", systemImage: "server.rack")

            Toggle(isOn: $settings.useMock) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("モックモード（サーバー不要）")
                        .font(.subheadline.weight(.medium))
                    Text("ダミーデータで動作します")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(Color.brandPrimary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("サーバーIPアドレス（または https:// から始まるURL）")
                    .font(.caption)
                    .foregroundStyle(settings.useMock ? Color.secondary.opacity(0.5) : .secondary)
                HStack(spacing: 8) {
                    Image(systemName: "network")
                        .foregroundStyle(settings.useMock ? Color.secondary.opacity(0.4) : Color.brandPrimary)
                    TextField("127.0.0.1", text: $settings.serverIP)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !settings.usesFullURL {
                        Text(":\(settings.serverPort)")
                            .font(.subheadline.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color.appBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .opacity(settings.useMock ? 0.45 : 1)
            .disabled(settings.useMock)
        }
        .card()
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "接続テスト", systemImage: "antenna.radiowaves.left.and.right")
            Button {
                Task { await runHealthCheck() }
            } label: {
                HStack {
                    if isChecking { ProgressView().controlSize(.small) }
                    Text("ヘルスチェック実行")
                }
            }
            .buttonStyle(.bordered)
            .tint(Color.brandPrimary)

            if let healthResult {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.brandAccent)
                    Text(healthResult).font(.subheadline.monospaced())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var zonesCard: some View {
        NavigationLink {
            ExclusionZonesView()
        } label: {
            HStack {
                Image(systemName: "house.and.flag.fill").foregroundStyle(Color.brandPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("マッチしない場所").font(.subheadline.weight(.medium)).foregroundStyle(Color.brandInk)
                    Text(zoneStore.zones.isEmpty
                         ? "自宅・職場などではすれ違わないようにする"
                         : "\(zoneStore.zones.filter(\.isEnabled).count)か所で停止" + (ble.activeZone.map { "（いま「\($0.name)」の中）" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private var privacyCard: some View {
        NavigationLink {
            BlocklistView()
        } label: {
            HStack {
                Image(systemName: "hand.raised.slash.fill").foregroundStyle(Color.brandPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ブロック中のユーザー").font(.subheadline.weight(.medium)).foregroundStyle(Color.brandInk)
                    Text("ブロックの確認・解除").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private var developerCard: some View {
        NavigationLink {
            DeveloperView()
        } label: {
            HStack {
                Image(systemName: "ladybug.fill").foregroundStyle(Color.brandPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("開発者画面").font(.subheadline.weight(.medium)).foregroundStyle(Color.brandInk)
                    Text("BLE検出ログ・UUID・RSSIなど").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private var logoutButton: some View {
        Button(role: .destructive) {
            session.signOut()
        } label: {
            HStack {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                Text("ログアウト")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.red.opacity(0.1))
            .foregroundStyle(.red)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var deleteAccountButton: some View {
        VStack(spacing: 8) {
            Button {
                showDeleteConfirm = true
            } label: {
                HStack {
                    if isDeleting { ProgressView().controlSize(.small) }
                    Image(systemName: "person.crop.circle.badge.xmark")
                    Text("アカウントを削除")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(.red)
            }
            .disabled(isDeleting)

            if let deleteError {
                Text(deleteError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// DELETE /users/me → 成功したら端末内のデータも消してログイン画面へ。
    /// 失敗（通信エラー等）のときは何も消さずにエラーを出す。
    private func deleteAccount() async {
        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }
        do {
            try await api.deleteAccount()
            // 前のアカウントの検出ログが次のアカウントに見えないよう消す
            // （送信クールダウン等は RootView がログアウト時にリセットする）
            ble.clearAllLogs()
            // 自宅などの位置を端末に残さない（再送キューは RootView がログアウト時に消す）
            zoneStore.removeAll()
            session.signOut(reason: "アカウントを削除しました。")
        } catch {
            deleteError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func runHealthCheck() async {
        isChecking = true
        defer { isChecking = false }
        do {
            healthResult = try await api.healthCheck()
        } catch {
            healthResult = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
