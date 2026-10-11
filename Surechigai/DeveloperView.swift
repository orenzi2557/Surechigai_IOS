//
//  DeveloperView.swift
//  Surechigai
//
//  開発者用画面（設計書 11章）。サーバを通さずローカルで得た情報を表示する。
//  ・自分のUUID / 相手のUUID / すれ違った時間 / 場所(緯度経度) / 信号強度(RSSI)
//

import SwiftUI
import CoreBluetooth

struct DeveloperView: View {
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var encounterSync: EncounterSync

    @State private var manualPeerUUID = ""
    @State private var manualResult: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                myInfoCard
                realBLETestCard
                sendStateCard
                retryQueueCard
                manualSendCard
                bleStateCard
                gattCard
                demoCard
                logsCard
            }
            .padding(20)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("開発者画面")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// すれ違いをサーバーへ送れているか（POST /encounters の結果）
    private var sendStateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "サーバー送信", systemImage: "arrow.up.circle")
            InfoRow(label: "送信成功", value: "\(encounterSync.sentCount) 件（うち再送 \(encounterSync.resentCount) 件）")
            InfoRow(label: "最後に送った相手", value: encounterSync.lastSentPeerUUID ?? "（まだ無し）", mono: true)
            if let status = encounterSync.lastStatus {
                InfoRow(label: "サーバー判定", value: Self.statusLabel(status))
            }
            if let reason = encounterSync.lastDropReason {
                InfoRow(label: "直近の見送り", value: reason)
            }
            if let error = encounterSync.lastError {
                Text("直近のエラー: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// 送れなかったすれ違い（端末に保存され、通信が戻ると送り直す）
    private var retryQueueCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "再送キュー（\(encounterSync.pending.count)件）", systemImage: "arrow.clockwise.circle")
            Text("圏外やサーバー停止で送れなかった検知です。15秒ごと・通信の復帰時・アプリを開いたときに、検知した時刻のまま送り直します。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(encounterSync.pending) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.peerUuid).font(.caption2.monospaced()).foregroundStyle(Color.brandInk)
                    Text("検知 \(item.detectedAt.formatted(date: .omitted, time: .standard))・試行\(item.attempts)回・\(item.lastError ?? "-")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Divider()
            }
            HStack(spacing: 12) {
                Button {
                    Task { await encounterSync.flushPending() }
                } label: {
                    Label("今すぐ再送", systemImage: "paperplane").font(.subheadline)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(Color.brandPrimary)
                Button(role: .destructive) {
                    encounterSync.clearPending()
                } label: {
                    Label("破棄", systemImage: "trash").font(.subheadline)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .disabled(encounterSync.pending.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// BLE を使えないシミュレータで、実機の検知と同じ経路を確かめる
    private var manualSendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "BLE検知として注入", systemImage: "paperplane")
            Text("相手のアカウントUUIDを入れると、BLEで検知したのと同じ経路（マッチしない場所の判定 → POST /encounters → 失敗時は再送キュー）を通ります。相手のUUIDは相手側の開発者画面「自分の情報」で確認できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("相手のアカウントUUID", text: $manualPeerUUID)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Color.appBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                if ble.injectDetection(peerUUID: manualPeerUUID) {
                    manualResult = "検知として注入しました。結果は上の「サーバー送信」「再送キュー」に出ます"
                } else {
                    manualResult = ble.activeZone.map { "マッチしない場所「\($0.name)」の中のため、検知されませんでした" }
                        ?? "マッチがオフのため、検知されませんでした"
                }
            } label: {
                Label("検知として注入", systemImage: "paperplane.fill")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brandPrimary)
            .disabled(manualPeerUUID.trimmingCharacters(in: .whitespaces).isEmpty)

            if let manualResult {
                Text(manualResult)
                    .font(.caption)
                    .foregroundStyle(Color.brandInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// 裏にいる相手を GATT で識別できているか
    private var gattCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "GATT フォールバック", systemImage: "link.circle")
            Text("相手のアプリが裏・画面ロック中だと LocalName が届かないため、接続して特性からUUIDを読みます（同じ端末へは20秒に1回まで）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            InfoRow(label: "読み取り成功", value: "\(ble.gattSuccessCount) 回")
            InfoRow(label: "読み取り失敗", value: "\(ble.gattFailureCount) 回")
            if let error = ble.lastGATTError {
                InfoRow(label: "直近の失敗", value: error)
            }
            InfoRow(label: "特性UUID", value: BLEManager.idCharacteristicUUID.uuidString, mono: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// POST /encounters の status を説明つきで表示する（それ以外の文字列はそのまま）
    private static func statusLabel(_ status: String) -> String {
        switch status {
        case "matched_pending": return "matched_pending（マッチ候補を作成／既にあり）"
        case "recorded":        return "recorded（ブロック関係のため記録のみ）"
        case "ignored":         return "ignored（どちらかがマッチOFFのため記録しない）"
        default:                return status
        }
    }

    private var myInfoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "自分の情報", systemImage: "person.fill.viewfinder")
            InfoRow(label: "アカウントUUID", value: session.uuid ?? KeychainStore.shared.uuid ?? "（未ログイン）", mono: true)
            InfoRow(label: "端末ID", value: ble.myDeviceID, mono: true)
            InfoRow(label: "サービスUUID", value: BLEManager.serviceUUID.uuidString, mono: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: 実機BLEテスト（本物のすれ違い確認）

    private var realBLETestCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "実機BLEテスト", systemImage: "dot.radiowaves.up.forward")

            if ble.isBLEUnsupported {
                Label("このデバイスではBLEを使えません。実機(iPhone)で、Bluetoothをオンにして試してください。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !ble.matchEnabled {
                Label("マッチがオフのため、発信・受信とも停止しています。ホームの「マッチを受け付ける」をオンにしてください。",
                      systemImage: "person.2.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle(isOn: $ble.advertiseEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("発信（アドバタイズ）").font(.subheadline.weight(.medium))
                    Text("自分の存在をまわりに知らせる").font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(Color.brandPrimary)

            Toggle(isOn: $ble.scanEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("スキャン（受信）").font(.subheadline.weight(.medium))
                    Text("まわりのSurechigaiユーザーを探す").font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(Color.brandPrimary)

            Divider()

            // いま実際に動いているかの表示（希望状態と実状態は別物）
            HStack(spacing: 10) {
                LiveStatusDot(label: "発信中", active: ble.isAdvertising)
                LiveStatusDot(label: "受信中", active: ble.isScanning)
            }

            Text("使い方: iPhoneを2台用意し、両方でこの画面を開いて発信・受信をオンにします。近づけると下の「検出ログ」に相手が「実機」バッジ付きで表示されればすれ違い成功です。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var bleStateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "BLE状態", systemImage: "dot.radiowaves.left.and.right")
            if let zone = ble.activeZone {
                InfoRow(label: "停止中", value: "マッチしない場所「\(zone.name)」の中")
            }
            InfoRow(label: "スキャン", value: ble.isScanning ? "ON" : "OFF")
            InfoRow(label: "アドバタイズ", value: ble.isAdvertising ? "ON" : "OFF")
            InfoRow(label: "Central", value: stateLabel(ble.centralState))
            InfoRow(label: "Peripheral", value: stateLabel(ble.peripheralState))
            InfoRow(label: "検出総数", value: "\(ble.totalCount) 件")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var demoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "デモ / ログ操作", systemImage: "wand.and.stars")
            Text("「テストデータ」はBLEを使わず疑似的に1件を注入します（シミュレータ確認用）。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    ble.injectMockDetection()
                } label: {
                    Label("テストデータを注入", systemImage: "plus.circle")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(Color.brandPrimary)

                Button(role: .destructive) {
                    ble.clearAllLogs()
                } label: {
                    Label("クリア", systemImage: "trash")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(ble.recentLogs.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "検出ログ（新着順）", systemImage: "list.bullet.rectangle")
            if ble.recentLogs.isEmpty {
                Text("まだ検出されていません。\n実機なら上の「実機BLEテスト」を、シミュレータなら「テストデータを注入」で確認できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(ble.recentLogs) { log in
                    DetectedPeerRow(log: log)
                    if log.id != ble.recentLogs.last?.id { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func stateLabel(_ state: CBManagerState) -> String {
        state.label
    }
}

// MARK: - 稼働状況ドット

private struct LiveStatusDot: View {
    let label: String
    let active: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 9, height: 9)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? Color.brandInk : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.appBackground)
        .clipShape(Capsule())
    }
}

extension CBManagerState {
    var label: String {
        switch self {
        case .poweredOn: return "ON"
        case .poweredOff: return "OFF"
        case .unauthorized: return "権限なし"
        case .unsupported: return "非対応"
        case .resetting: return "リセット中"
        case .unknown: return "不明"
        @unknown default: return "不明"
        }
    }
}

private struct DetectedPeerRow: View {
    let log: DetectedPeer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(log.source.rawValue)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(sourceColor.opacity(0.15))
                    .foregroundStyle(sourceColor)
                    .clipShape(Capsule())
                Text("\(log.rssi) dBm")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(rssiColor.opacity(0.15))
                    .foregroundStyle(rssiColor)
                    .clipShape(Capsule())
                Text(log.proximityLabel).font(.caption).foregroundStyle(.secondary)
                Text(log.identitySource.rawValue)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.brandPrimary.opacity(0.12))
                    .foregroundStyle(Color.brandPrimary)
                    .clipShape(Capsule())
                Spacer()
                Text(log.timestamp, style: .time)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("相手の端末ID: \(log.peripheralID)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            // サーバーへ送る peer_uuid。復元できない相手は送信対象外になる。
            if let peerUUID = log.peerAccountUUID {
                Text("相手のアカウントUUID: \(peerUUID)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("相手のアカウントUUID: 復元不可（送信対象外）")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.orange)
            }
            if let lat = log.latitude, let lon = log.longitude {
                Text(String(format: "位置: %.5f, %.5f", lat, lon))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            } else {
                Text("位置: 取得なし")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var rssiColor: Color {
        if log.rssi >= -60 { return .red }
        else if log.rssi >= -75 { return .orange }
        else if log.rssi >= -90 { return .yellow }
        else { return .gray }
    }

    private var sourceColor: Color {
        log.source == .ble ? Color.brandAccent : Color.gray
    }
}
