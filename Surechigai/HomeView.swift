//
//  HomeView.swift
//  Surechigai
//
//  「すれ違った人一覧」画面。マッチの承認導線の起点。
//

import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var encounterSync: EncounterSync

    @State private var encounters: [EncounterResponse] = []
    @State private var matchEnabled = true
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    statusCard
                    matchToggleCard

                    HStack {
                        SectionHeader(title: "すれ違った人", systemImage: "person.2.wave.2")
                        if isLoading { ProgressView().controlSize(.small) }
                    }
                    .padding(.top, 4)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card()
                    }

                    if encounters.isEmpty && !isLoading {
                        EmptyStateView(
                            systemImage: "sparkles",
                            title: "まだ誰ともすれ違っていません",
                            message: "Bluetoothをオンにして街に出かけてみましょう"
                        )
                        .card()
                    } else {
                        ForEach(encounters) { encounter in
                            NavigationLink {
                                EncounterDetailView(encounter: encounter) {
                                    Task { await load() }
                                }
                            } label: {
                                EncounterRow(encounter: encounter)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("ホーム")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task { await load() }
            // すれ違いを送信できたら一覧に反映する（アプリを開いたまま新しい相手とすれ違った場合）
            .onChange(of: encounterSync.sentCount) { _, _ in
                Task { await load() }
            }
            // バックグラウンドから戻ったとき最新にする
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.willEnterForegroundNotification
            )) { _ in
                Task { await load() }
            }
        }
    }

    // MARK: ステータスカード

    private var statusCard: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("こんにちは、")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                    Text(session.currentUser?.displayName ?? "ユーザー")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.9))
            }
            HStack(spacing: 10) {
                StatusPill(label: "スキャン", on: ble.isScanning)
                StatusPill(label: "発信", on: ble.isAdvertising)
                StatusPill(label: "検出", text: "\(ble.totalCount)件")
            }
            if let zone = ble.activeZone {
                Label("マッチしない場所「\(zone.name)」にいるため停止中", systemImage: "pause.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
        .padding(20)
        .background(LinearGradient.brand)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.cardCorner, style: .continuous))
        .shadow(color: Color.brandPrimary.opacity(0.3), radius: 14, x: 0, y: 8)
    }

    private var matchToggleCard: some View {
        Toggle(isOn: $matchEnabled) {
            HStack(spacing: 12) {
                Image(systemName: matchEnabled ? "person.2.fill" : "person.2.slash")
                    .foregroundStyle(Color.brandPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("マッチを受け付ける")
                        .font(.subheadline.weight(.medium))
                    Text(matchEnabled ? "すれ違いをマッチ候補にします" : "現在オフです")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(Color.brandPrimary)
        .card()
        .onChange(of: matchEnabled) { _, newValue in
            Task { await updateMatch(newValue) }
        }
    }

    // MARK: ロジック

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // 2つの取得が「両方とも」終わってから状態を書き換える。
            // 途中で session/ble を書き換えると画面が作り直され、
            // まだ実行中だったリクエストが巻き込まれてキャンセルされる
            // （引っぱって更新したときに "cancelled" と出ていた原因）。
            async let me = api.fetchMe()
            async let list = api.fetchEncounters()
            let (user, fetched) = try await (me, list)

            session.currentUser = user
            matchEnabled = user.matchEnabled
            ble.matchEnabled = user.matchEnabled
            encounters = fetched.sorted { $0.detectedAt > $1.detectedAt }
        } catch {
            // キャンセルは画面の作り直しなどで普通に起きる。失敗として見せない。
            if Self.isCancellation(error) { return }
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 通信のキャンセルかどうか（URLSessionは -999 / NSURLErrorCancelled を返す）
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        // APIClient は URLSession の失敗を文字列にして包むため、そこも見る
        if case let .underlying(detail)? = error as? APIError {
            return detail.localizedCaseInsensitiveContains("cancel")
        }
        return false
    }

    private func updateMatch(_ enabled: Bool) async {
        // BLEは即座に止める/動かす。サーバーへは値の保存のみで、判定はクライアント側で行う。
        ble.matchEnabled = enabled
        do {
            _ = try await api.updateMe(UpdateMeRequest(
                displayName: nil, age: nil, gender: nil, bio: nil,
                matchEnabled: enabled, tags: nil
            ))
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - ステータスピル

private struct StatusPill: View {
    let label: String
    var on: Bool? = nil
    var text: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let on {
                Circle()
                    .fill(on ? Color.green : Color.white.opacity(0.4))
                    .frame(width: 8, height: 8)
            }
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
            if let text {
                Text(text)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.white.opacity(0.18))
        .clipShape(Capsule())
    }
}

// MARK: - すれ違い1件の行

struct EncounterRow: View {
    let encounter: EncounterResponse

    var body: some View {
        HStack(spacing: 14) {
            Avatar(name: encounter.peerDisplayName, url: encounter.peerProfileImageUrl, size: 54)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(encounter.peerDisplayName)
                        .font(.headline)
                        .foregroundStyle(Color.brandInk)
                    Spacer()
                    StatusBadge(status: encounter.status)
                }
                if !encounter.peerTags.isEmpty {
                    Text(encounter.peerTags.prefix(3).map { "#\($0)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(Color.brandPrimary)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Label(encounter.detectedAt.relativeString, systemImage: "clock")
                    if let rssi = encounter.rssi {
                        Label("\(rssi)dBm", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

// MARK: - マッチ状態バッジ

struct StatusBadge: View {
    let status: MatchStatus
    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
    private var color: Color {
        switch status {
        case .approved: return Color.brandAccent
        case .pending:  return Color.orange
        case .rejected: return Color.gray
        }
    }
}

// MARK: - 日付の相対表示

extension Date {
    var relativeString: String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }
}
