//
//  MockData.swift
//  Surechigai
//
//  モックモード（サーバー不要）で返す固定ダミーデータ。
//

import Foundation

enum MockData {

    /// fetchMe で返す自分のプロフィール
    static let me = UserResponse(
        uuid: "mock-uuid-1234",
        loginId: "demo_user",
        displayName: "デモユーザー",
        age: 24,
        gender: "未設定",
        bio: "すれ違いアプリのデモ用アカウントです。カフェ巡りと音楽が好き。",
        profileImageUrl: nil,
        matchEnabled: true,
        tags: ["カフェ", "音楽", "写真", "散歩"],
        snsLinks: [
            SNSLink(platform: "X", url: "https://x.com/demo_user"),
            SNSLink(platform: "Instagram", url: "https://instagram.com/demo_user"),
        ]
    )

    /// updateMe の結果（送られてきた値で me を上書きしたもの）
    static func updatedMe(from req: UpdateMeRequest) -> UserResponse {
        UserResponse(
            uuid: me.uuid,
            loginId: me.loginId,
            displayName: req.displayName ?? me.displayName,
            age: req.age ?? me.age,
            gender: req.gender ?? me.gender,
            bio: req.bio ?? me.bio,
            profileImageUrl: me.profileImageUrl,
            matchEnabled: req.matchEnabled ?? me.matchEnabled,
            tags: req.tags ?? me.tags,
            snsLinks: me.snsLinks
        )
    }

    /// fetchEncounters で返すすれ違い履歴（相手情報つき）
    private(set) static var encounters: [EncounterResponse] = [
        EncounterResponse(
            id: 1,
            peerUuid: "peer-uuid-aaaa",
            peerDisplayName: "Haruka",
            peerBio: "本屋さんでよく見かけるかも。読書と映画が趣味です。",
            peerProfileImageUrl: nil,
            peerTags: ["読書", "映画", "カフェ"],
            peerSnsLinks: nil,
            detectedAt: Date().addingTimeInterval(-600),     // 10分前
            rssi: -58,
            latitude: 35.6586,
            longitude: 139.7454,
            matchStatus: MatchStatus.pending.rawValue,
            approvedByMe: false,
            approvedByPeer: true
        ),
        EncounterResponse(
            id: 2,
            peerUuid: "peer-uuid-bbbb",
            peerDisplayName: "Kenta",
            peerBio: "ランニング仲間募集中。週末は代々木公園にいます。",
            peerProfileImageUrl: nil,
            peerTags: ["ランニング", "音楽"],
            peerSnsLinks: [
                SNSLink(platform: "X", url: "https://x.com/kenta_run"),
                SNSLink(platform: "Instagram", url: "https://instagram.com/kenta_run"),
            ],
            detectedAt: Date().addingTimeInterval(-3600 * 3), // 3時間前
            rssi: -72,
            latitude: 35.6705,
            longitude: 139.7027,
            matchStatus: MatchStatus.approved.rawValue,
            approvedByMe: true,
            approvedByPeer: true
        ),
        EncounterResponse(
            id: 3,
            peerUuid: "peer-uuid-cccc",
            peerDisplayName: "Mio",
            peerBio: "写真を撮るのが好きです。",
            peerProfileImageUrl: nil,
            peerTags: ["写真", "散歩", "カフェ"],
            peerSnsLinks: nil,
            detectedAt: Date().addingTimeInterval(-3600 * 26), // 約1日前
            rssi: -85,
            latitude: 35.6897,
            longitude: 139.7006,
            matchStatus: MatchStatus.pending.rawValue,
            approvedByMe: false,
            approvedByPeer: false
        ),
    ]

    // MARK: - ブロック（モック）

    /// モック時のブロック中ユーザー。ローカルに保持して増減させる。
    private(set) static var blockedUsers: [BlockedUser] = [
        BlockedUser(uuid: "peer-uuid-dddd", displayName: "ブロック中のユーザー"),
    ]

    static func blockLocally(uuid: String) {
        guard !blockedUsers.contains(where: { $0.uuid == uuid }) else { return }
        // すれ違い一覧から表示名を引ければ使う
        let name = encounters.first { $0.peerUuid == uuid }?.peerDisplayName ?? "ブロックした相手"
        blockedUsers.append(BlockedUser(uuid: uuid, displayName: name))
    }

    static func unblockLocally(uuid: String) {
        blockedUsers.removeAll { $0.uuid == uuid }
    }

    /// ブロック中の相手を除いたすれ違い一覧（サーバーの /encounters と同じ挙動）
    static var visibleEncounters: [EncounterResponse] {
        let blocked = Set(blockedUsers.map(\.uuid))
        return encounters.filter { !blocked.contains($0.peerUuid) }
    }

    /// 見送り（reject）をモック上でも保持する
    static func rejectLocally(uuid: String) {
        guard let i = encounters.firstIndex(where: { $0.peerUuid == uuid }) else { return }
        let e = encounters[i]
        encounters[i] = replacing(e, status: .rejected, approvedByMe: false)
    }

    /// 承認をモック上でも保持する。相手も承認済みなら成立（サーバーと同じ判定）
    static func approveLocally(uuid: String) -> MatchStatus {
        guard let i = encounters.firstIndex(where: { $0.peerUuid == uuid }) else { return .pending }
        let e = encounters[i]
        let status: MatchStatus = e.approvedByPeer ? .approved : .pending
        encounters[i] = replacing(e, status: status, approvedByMe: true)
        return status
    }

    private static func replacing(_ e: EncounterResponse, status: MatchStatus, approvedByMe: Bool) -> EncounterResponse {
        EncounterResponse(
            id: e.id,
            peerUuid: e.peerUuid,
            peerDisplayName: e.peerDisplayName,
            peerBio: e.peerBio,
            peerProfileImageUrl: e.peerProfileImageUrl,
            peerTags: e.peerTags,
            peerSnsLinks: e.peerSnsLinks,
            detectedAt: e.detectedAt,
            rssi: e.rssi,
            latitude: e.latitude,
            longitude: e.longitude,
            matchStatus: status.rawValue,
            approvedByMe: approvedByMe,
            approvedByPeer: e.approvedByPeer
        )
    }

    /// GET /users/{uuid} のモック。すれ違い一覧にいる相手だけ返す（サーバーと同じく他は404）
    static func publicUser(uuid: String) throws -> PublicUserResponse {
        guard let e = visibleEncounters.first(where: { $0.peerUuid == uuid }) else {
            throw APIError.server(status: 404, message: #"{"detail":"ユーザーが見つかりません"}"#)
        }
        return PublicUserResponse(
            uuid: e.peerUuid,
            displayName: e.peerDisplayName,
            age: nil,
            gender: nil,
            bio: e.peerBio,
            profileImageUrl: e.peerProfileImageUrl,
            tags: e.peerTags,
            snsLinks: e.status == .approved ? (e.peerSnsLinks ?? []) : []
        )
    }

    // MARK: - マップピン（モック）

    static func addPinLocally(_ pin: MapPin) {
        mapPins.insert(pin, at: 0)
    }

    static func updatePinLocally(id: Int, _ update: MapPinUpdate) throws -> MapPin {
        guard let i = mapPins.firstIndex(where: { $0.id == id }) else {
            throw APIError.server(status: 404, message: #"{"detail":"ピンが見つかりません"}"#)
        }
        guard mapPins[i].isMine else {
            throw APIError.server(status: 403, message: #"{"detail":"自分のピンのみ編集できます"}"#)
        }
        let p = mapPins[i]
        let updated = MapPin(
            id: p.id,
            message: update.message ?? p.message,
            latitude: update.latitude ?? p.latitude,
            longitude: update.longitude ?? p.longitude,
            createdAt: p.createdAt,
            isMine: p.isMine
        )
        mapPins[i] = updated
        return updated
    }

    static func deletePinLocally(id: Int) {
        mapPins.removeAll { $0.id == id }
    }

    /// 匿名マップピン（モック）
    private(set) static var mapPins: [MapPin] = [
        MapPin(id: 1, message: "ここでよくすれ違う☕️", latitude: 35.6586, longitude: 139.7454, createdAt: Date().addingTimeInterval(-7200), isMine: true),
        MapPin(id: 2, message: "朝のランニングコース🏃", latitude: 35.6705, longitude: 139.7027, createdAt: Date().addingTimeInterval(-18000), isMine: false),
        MapPin(id: 3, message: "お気に入りの本屋📚", latitude: 35.6897, longitude: 139.7006, createdAt: Date().addingTimeInterval(-86400), isMine: false),
    ]
}
