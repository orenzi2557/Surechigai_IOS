//
//  Models.swift
//  Surechigai
//
//  サーバー(FastAPI)とやり取りするデータモデル。
//  デコードは JSONDecoder の .convertFromSnakeCase + .iso8601 を前提にする。
//

import Foundation

// MARK: - 認証

/// /auth/login, /auth/register のレスポンス
struct AuthResponse: Codable {
    let accessToken: String      // access_token
    let uuid: String
    let displayName: String?     // display_name
}

// MARK: - ユーザー

/// /users/me, /users/{uuid} のレスポンス
struct UserResponse: Codable, Identifiable {
    var id: String { uuid }

    let uuid: String
    let loginId: String          // login_id
    let displayName: String      // display_name
    let age: Int?
    let gender: String?
    let bio: String?
    let profileImageUrl: String? // profile_image_url
    let matchEnabled: Bool       // match_enabled
    let tags: [String]
    let snsLinks: [SNSLink]      // sns_links
}

/// GET /users/{uuid} のレスポンス（すれ違った相手の公開プロフィール）。
/// login_id と match_enabled は含まれない。sns_links は相互承認(approved)時のみ中身が入る。
struct PublicUserResponse: Codable, Identifiable {
    var id: String { uuid }

    let uuid: String
    let displayName: String      // display_name
    let age: Int?
    let gender: String?
    let bio: String?
    let profileImageUrl: String? // profile_image_url
    let tags: [String]
    let snsLinks: [SNSLink]      // sns_links
}

/// SNSリンク（相互承認後に開示）
struct SNSLink: Codable, Identifiable, Hashable {
    var id: String { platform + url }
    let platform: String         // 例: "X", "Instagram"
    let url: String
}

// MARK: - すれ違い / マッチ

/// /encounters のレスポンス（相手情報つき）
struct EncounterResponse: Codable, Identifiable {
    let id: Int
    let peerUuid: String             // peer_uuid
    let peerDisplayName: String      // peer_display_name
    let peerBio: String?             // peer_bio
    let peerProfileImageUrl: String? // peer_profile_image_url
    let peerTags: [String]           // peer_tags
    let peerSnsLinks: [SNSLink]?     // peer_sns_links（approvedのときのみ）
    let detectedAt: Date             // detected_at
    let rssi: Int?
    let latitude: Double?
    let longitude: Double?
    let matchStatus: String          // match_status: pending / approved / rejected
    let approvedByMe: Bool           // approved_by_me
    let approvedByPeer: Bool         // approved_by_peer
    var detectionMethod: String? = nil // detection_method（現状は常に "ble"）

    var status: MatchStatus { MatchStatus(rawValue: matchStatus) ?? .pending }
}

enum MatchStatus: String {
    case pending
    case approved
    case rejected

    var label: String {
        switch self {
        case .pending:  return "承認待ち"
        case .approved: return "マッチ成立"
        case .rejected: return "見送り"
        }
    }
}

// MARK: - リクエストボディ

struct LoginRequest: Codable {
    let loginId: String
    let password: String
}

struct RegisterRequest: Codable {
    let loginId: String
    let password: String
    let displayName: String
    let tags: [String]
}

struct UpdateMeRequest: Codable {
    let displayName: String?
    let age: Int?
    let gender: String?
    let bio: String?
    let matchEnabled: Bool?
    let tags: [String]?
}

struct EncounterUpload: Codable {
    let peerUuid: String
    let rssi: Int?
    let latitude: Double?
    let longitude: Double?
    let detectedAt: Date
}

struct MapPinCreate: Codable {
    let message: String
    let latitude: Double
    let longitude: Double
}

/// PATCH /map_pins/{id} のリクエストボディ（nil のフィールドは送らない＝変更なし）
struct MapPinUpdate: Codable {
    var message: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
}

/// {"status": "..."} だけを返すAPIのレスポンス
/// （POST /encounters, /matches/{uuid}/approve など）
struct SimpleStatus: Codable {
    let status: String
}

/// PUT /users/me/sns_links のリクエストボディ
struct SNSLinksUpdate: Codable {
    let snsLinks: [SNSLink]      // sns_links
}

// MARK: - ブロック

/// POST /blocklist のリクエストボディ
struct BlockRequest: Codable {
    let targetUuid: String       // target_uuid
}

/// GET /blocklist のレスポンス要素
struct BlockedUser: Codable, Identifiable {
    var id: String { uuid }

    let uuid: String
    let displayName: String      // display_name
}

// MARK: - エラー

enum APIError: LocalizedError {
    case invalidURL
    case server(status: Int, message: String?)
    case decoding(String)
    case notAuthenticated
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "サーバーURLが不正です"
        case let .server(status, message):
            // FastAPI のエラーは {"detail": "日本語メッセージ"} の形なので、中身だけを見せる
            if let detail = Self.detail(from: message) {
                return "\(detail)（\(status)）"
            }
            return "サーバーエラー(\(status))" + (message.map { ": \($0)" } ?? "")
        case let .decoding(detail):
            return "レスポンスの解析に失敗しました: \(detail)"
        case .notAuthenticated:
            return "ログインが必要です"
        case let .underlying(detail):
            return detail
        }
    }

    /// HTTPステータスコード（サーバーエラーのときのみ）
    var statusCode: Int? {
        if case let .server(status, _) = self { return status }
        return nil
    }

    /// エラー本文の detail を取り出す。
    /// 通常は文字列、バリデーションエラー(422)は [{"loc":..., "msg":...}] の配列で返る。
    private static func detail(from body: String?) -> String? {
        guard let data = body?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let text = json["detail"] as? String { return text }
        if let items = json["detail"] as? [[String: Any]] {
            let messages = items.compactMap { item -> String? in
                guard let msg = item["msg"] as? String else { return nil }
                let field = (item["loc"] as? [Any])?.last.map { "\($0)" }
                return field.map { "\($0): \(msg)" } ?? msg
            }
            return messages.isEmpty ? nil : "入力内容を確認してください（" + messages.joined(separator: " / ") + "）"
        }
        return nil
    }
}
