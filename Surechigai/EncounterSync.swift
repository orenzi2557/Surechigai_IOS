//
//  EncounterSync.swift
//  Surechigai
//
//  BLEで検知したすれ違いをサーバーへ送る（POST /encounters）。
//  設計書v3の中核：片方向の送信でサーバーがマッチをpendingで作成する。
//
//  BLEManager は検知だけを担当し、サーバー送信はこのクラスが受け持つ。
//
//  ★ 再送キュー ★
//  圏外・サーバー停止などで送れなかった検知は端末に保存し、あとで送り直す。
//  ・detected_at は検知した時刻のまま送る（サーバーは送信時刻ではなくこの値を記録する）
//  ・再送の間にどちらかがマッチOFFにしていれば、サーバーが ignored を返して記録しない
//  ・相手が退会済み(404)など、送り直しても通らないものは捨てる
//  ・キューはアカウントごと。ログアウト時に消し、別アカウントとして送られないようにする
//

import Foundation
import Combine
import Network
import UIKit

/// 送信待ちのすれ違い1件（端末に保存する）
struct PendingEncounter: Codable, Identifiable, Hashable {
    var id = UUID()
    /// 検知したときにログインしていたアカウント（別アカウントで送らないための確認用）
    let ownerUUID: String
    let peerUuid: String
    let rssi: Int?
    let latitude: Double?
    let longitude: Double?
    let detectedAt: Date
    var attempts = 0
    var lastError: String?

    var upload: EncounterUpload {
        EncounterUpload(peerUuid: peerUuid, rssi: rssi, latitude: latitude, longitude: longitude, detectedAt: detectedAt)
    }
}

@MainActor
final class EncounterSync: ObservableObject {

    /// 同じ相手へ連続送信しないための間隔。
    /// 設計書3.4の本来の仕様は「同じ相手とは1日1回」だが、現状は実験のため無制限。
    /// ここでは送信が毎秒何度も走るのを防ぐ目的だけで短い間隔を置く。
    private let sendInterval: TimeInterval = 60
    /// 再送キューを送り直す間隔（キューが空でなければ）
    private let retryInterval: TimeInterval = 15
    /// 保存しておく上限（古いものから捨てる）
    private let maxPending = 200
    private let pendingKey = "encounterSync.pending"

    private let api: APIClient
    private var lastSentAt: [String: Date] = [:]
    private var retryTimer: Timer?
    private var isFlushing = false
    private let pathMonitor = NWPathMonitor()

    /// いまログインしているアカウント（RootView が設定する）。nil の間は送らない
    var currentUserUUID: String? {
        didSet {
            guard currentUserUUID != oldValue else { return }
            // 別のアカウントの検知は送らない
            pending.removeAll { $0.ownerUUID != currentUserUUID }
            if currentUserUUID != nil { Task { await flushPending() } }
        }
    }

    /// 送る直前の最終チェック。マッチしない場所で記録された検知などを弾く（RootView が設定する）
    var shouldDrop: ((DetectedPeer) -> String?)?

    /// 開発者画面での確認用。
    @Published private(set) var sentCount = 0
    @Published private(set) var lastSentPeerUUID: String?
    @Published private(set) var lastError: String?
    /// 直近の送信に対するサーバーの判定（matched_pending / recorded / ignored）
    @Published private(set) var lastStatus: String?
    /// 送信を見送った直近の理由（マッチしない場所 など）
    @Published private(set) var lastDropReason: String?
    /// 再送キュー（端末に保存）
    @Published private(set) var pending: [PendingEncounter] = [] {
        didSet { savePending() }
    }
    /// 再送で送れた件数
    @Published private(set) var resentCount = 0

    init(api: APIClient) {
        self.api = api
        if let data = UserDefaults.standard.data(forKey: pendingKey),
           let decoded = try? JSONDecoder().decode([PendingEncounter].self, from: data) {
            pending = decoded
        }
        startRetryTimer()
        // 通信が戻ったらすぐ送り直す
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.flushPending() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "EncounterSync.path"))
        // アプリが前面に戻ったときも送り直す
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.flushPending() }
        }
    }

    /// ログアウト時に呼ぶ。再送キューも消す（次にログインした別アカウントとして送られないように）
    func reset() {
        lastSentAt.removeAll()
        sentCount = 0
        resentCount = 0
        lastSentPeerUUID = nil
        lastError = nil
        lastStatus = nil
        lastDropReason = nil
        pending = []
    }

    /// 検知1件を受け取り、送信すべきものだけをサーバーへ送る。
    func handle(_ peer: DetectedPeer, myUUID: String?) {
        // アドバタイズからアカウントUUIDを復元できないものは送れない。
        // （相手がログイン前、あるいは他アプリのBLE機器を拾った場合）
        guard let peerUUID = peer.peerAccountUUID else { return }
        guard let owner = myUUID?.lowercased(), peerUUID != owner else { return }

        if let reason = shouldDrop?(peer) {
            lastDropReason = reason
            print("[すれ違い送信] 見送り: 相手=\(peerUUID) 理由=\(reason)")
            return
        }

        let now = Date()
        // 開発者画面からの注入（source == .mock）は確認用なので間隔を空けない
        if peer.source == .ble, let last = lastSentAt[peerUUID], now.timeIntervalSince(last) < sendInterval { return }
        lastSentAt[peerUUID] = now

        let item = PendingEncounter(
            ownerUUID: owner,
            peerUuid: peerUUID,
            rssi: peer.rssi,
            latitude: peer.latitude,
            longitude: peer.longitude,
            detectedAt: peer.timestamp
        )
        Task { await send(item, isRetry: false) }
    }

    /// 再送キューを今すぐ送り直す（開発者画面のボタン・タイマー・通信復帰・前面復帰から呼ぶ）
    func flushPending() async {
        guard !isFlushing, !pending.isEmpty, let owner = currentUserUUID?.lowercased() else { return }
        isFlushing = true
        defer { isFlushing = false }

        // 古い順に送る（サーバーは同じ相手の行を上書きするので、新しい検知を最後に届ける）
        let items = pending.filter { $0.ownerUUID == owner }.sorted { $0.detectedAt < $1.detectedAt }
        for item in items {
            // 送っている間にログアウト・アカウント切り替えがあれば中断
            guard currentUserUUID?.lowercased() == owner else { return }
            pending.removeAll { $0.id == item.id }
            let ok = await send(item, isRetry: true)
            // 通信エラーが続くなら残りも通らないので、次の機会にまとめて送る
            if !ok, pending.contains(where: { $0.id == item.id }) { break }
        }
    }

    func clearPending() {
        pending = []
    }

    // MARK: - 送信

    /// 1件送る。送れた・捨てたなら true、再送キューに戻したなら false。
    @discardableResult
    private func send(_ item: PendingEncounter, isRetry: Bool) async -> Bool {
        // 裏にいるときに送信が途中で止められないよう、少しだけ実行時間をもらう
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "postEncounter")
        defer { UIApplication.shared.endBackgroundTask(taskID) }

        do {
            let status = try await api.sendEncounter(item.upload)
            sentCount += 1
            if isRetry { resentCount += 1 }
            lastSentPeerUUID = item.peerUuid
            lastStatus = status
            lastError = nil
            // 同じ相手の、これより古い送信待ちは不要（サーバーは最新で上書きするだけ）
            pending.removeAll { $0.peerUuid == item.peerUuid && $0.detectedAt <= item.detectedAt }
            print("[すれ違い送信] 成功\(isRetry ? "(再送)" : ""): 相手=\(item.peerUuid) 結果=\(status)")
            return true
        } catch {
            let message = (error as? APIError)?.errorDescription ?? error.localizedDescription
            lastError = message
            lastSentAt[item.peerUuid] = nil

            guard Self.isRetryable(error) else {
                // 400(自分自身) / 404(相手が存在しない・退会) / 401(ログアウトされる) など。送り直しても通らない
                print("[すれ違い送信] 失敗(再送しない): 相手=\(item.peerUuid) 理由=\(message)")
                return true
            }
            // 送信中にログアウト・切り替えがあった分は、別アカウントのキューに入れない
            guard currentUserUUID?.lowercased() == item.ownerUUID else { return true }

            var queued = item
            queued.attempts += 1
            queued.lastError = message
            // 同じ相手の古い送信待ちは1件にまとめる（新しい方を残す）
            pending.removeAll { $0.peerUuid == item.peerUuid && $0.detectedAt <= item.detectedAt }
            pending.append(queued)
            if pending.count > maxPending {
                pending.removeFirst(pending.count - maxPending)
            }
            print("[すれ違い送信] 失敗→再送キューへ(\(pending.count)件): 相手=\(item.peerUuid) 理由=\(message)")
            return false
        }
    }

    /// 送り直す価値のある失敗か（通信エラー・タイムアウト・サーバー側の一時的なエラー）
    private static func isRetryable(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return true }
        switch apiError {
        case .underlying:
            return true                       // 圏外・接続拒否・タイムアウト
        case let .server(status, _):
            return status >= 500 || status == 429 || status == 408
        case .invalidURL, .decoding, .notAuthenticated:
            return false
        }
    }

    private func startRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.flushPending() }
        }
    }

    private func savePending() {
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: pendingKey)
        }
    }
}
