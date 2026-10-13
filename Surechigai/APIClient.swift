//
//  APIClient.swift
//  Surechigai
//
//  サーバー(FastAPI)との通信を担うクライアント。
//
//  ★ モックモード対応 ★
//  AppSettings.useMock が true のときは、実際の通信を行わず
//  300ms ほど遅延させてから固定のダミーデータを返す。
//  本物の通信コード（URLSession 部分）は消さずに if 分岐で必ず残してある。
//

import Foundation

@MainActor
final class APIClient: ObservableObject {

    private let settings: AppSettings

    /// 認証付きリクエストが 401 を返したときに呼ばれる。
    /// （トークン期限切れ・別端末でのアカウント削除・トークン世代の更新など）
    /// RootView がここでログアウトさせる。
    var onUnauthorized: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - 共通設定

    private var baseURL: URL? {
        URL(string: settings.baseURLString)
    }

    private var authToken: String? {
        KeychainStore.shared.token
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// 共有セッション。
    /// タイムアウトを明示しないと、応答しないIP（Wi-Fi違い・サーバー停止）を指したとき
    /// 既定の60秒までスピナーが回り続けるため、実機検証しやすい長さに縮めている。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60   // 画像アップロードを考慮して長め
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// モック時の擬似ネットワーク遅延
    private func mockDelay() async {
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
    }

    // MARK: - 認証

    func login(loginId: String, password: String) async throws -> AuthResponse {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] login: id=\(loginId) → 成功")
            return AuthResponse(
                accessToken: "mock-token",
                uuid: "mock-uuid-1234",
                displayName: loginId
            )
        }

        // ── 本番通信 ──────────────────────────────
        let body = LoginRequest(loginId: loginId, password: password)
        return try await request(
            path: "/auth/login",
            method: "POST",
            body: body,
            authorized: false
        )
    }

    func register(loginId: String, password: String, displayName: String, tags: [String]) async throws -> AuthResponse {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] register: id=\(loginId) → 成功")
            return AuthResponse(
                accessToken: "mock-token",
                uuid: "mock-uuid-1234",
                displayName: loginId
            )
        }

        // ── 本番通信 ──────────────────────────────
        let body = RegisterRequest(
            loginId: loginId,
            password: password,
            displayName: displayName.isEmpty ? loginId : displayName,
            tags: tags
        )
        return try await request(
            path: "/auth/register",
            method: "POST",
            body: body,
            authorized: false
        )
    }

    // MARK: - ユーザー

    func fetchMe() async throws -> UserResponse {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] fetchMe → ダミープロフィール返却")
            return MockData.me
        }

        // ── 本番通信 ──────────────────────────────
        return try await request(path: "/users/me", method: "GET", authorized: true)
    }

    func updateMe(_ req: UpdateMeRequest) async throws -> UserResponse {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] updateMe → 成功（display=\(req.displayName ?? "-"), tags=\(req.tags ?? []))")
            return MockData.updatedMe(from: req)
        }

        // ── 本番通信 ──────────────────────────────
        return try await request(path: "/users/me", method: "PATCH", body: req, authorized: true)
    }

    /// SNSリンクを丸ごと置き換える（PUT /users/me/sns_links）。更新後のプロフィールを返す。
    func updateSNSLinks(_ links: [SNSLink]) async throws -> UserResponse {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] updateSNSLinks → 成功（\(links.count)件）")
            let m = MockData.me
            return UserResponse(
                uuid: m.uuid,
                loginId: m.loginId,
                displayName: m.displayName,
                age: m.age,
                gender: m.gender,
                bio: m.bio,
                profileImageUrl: m.profileImageUrl,
                matchEnabled: m.matchEnabled,
                tags: m.tags,
                snsLinks: links
            )
        }

        // ── 本番通信 ──────────────────────────────
        let body = SNSLinksUpdate(snsLinks: links)
        return try await request(path: "/users/me/sns_links", method: "PUT", body: body, authorized: true)
    }

    /// プロフィール画像アップロード。成功すると新しい画像URLを返す。
    func uploadImage(_ data: Data) async throws -> String {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] uploadImage → 成功（\(data.count) bytes をアップロードしたつもり）")
            return "mock://profile-image.jpg"
        }

        // ── 本番通信（multipart/form-data）──────────
        // 呼び出し側(ImageProcessing)でJPEGに揃えてから渡す前提なので、
        // ファイル名と Content-Type は image/jpeg 固定でよい。
        // ※サーバーは拡張子で保存形式を決める（users.py の upload_image）
        guard let url = baseURL?.appendingPathComponent("users/me/image") else {
            throw APIError.invalidURL
        }
        guard let token = authToken else { throw APIError.notAuthenticated }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var formData = Data()
        formData.append("--\(boundary)\r\n".data(using: .utf8)!)
        formData.append("Content-Disposition: form-data; name=\"file\"; filename=\"profile.jpg\"\r\n".data(using: .utf8)!)
        formData.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        formData.append(data)
        formData.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = formData

        let (respData, response) = try await Self.session.data(for: req)
        try validate(response, data: respData, authorized: true)
        struct ImageResponse: Codable { let profileImageUrl: String }
        let decoded = try Self.decoder.decode(ImageResponse.self, from: respData)
        return decoded.profileImageUrl
    }

    /// すれ違った相手の公開プロフィール（GET /users/{uuid}）。
    /// すれ違っていない・ブロック関係・退会済みの相手は 404 になる。
    func fetchUser(uuid: String) async throws -> PublicUserResponse {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] fetchUser → 相手=\(uuid)")
            return try MockData.publicUser(uuid: uuid)
        }

        // ── 本番通信 ──────────────────────────────
        return try await request(path: "/users/\(uuid.lowercased())", method: "GET", authorized: true)
    }

    /// アカウント削除（DELETE /users/me）。成功するとサーバー上の本人データはすべて消え、トークンも無効になる。
    func deleteAccount() async throws {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] deleteAccount → 成功")
            return
        }

        // ── 本番通信 ──────────────────────────────
        try await requestVoid(path: "/users/me", method: "DELETE", authorized: true)
    }

    // MARK: - すれ違い / マッチ

    func fetchEncounters() async throws -> [EncounterResponse] {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] fetchEncounters → ダミー\(MockData.visibleEncounters.count)件返却")
            return MockData.visibleEncounters
        }

        // ── 本番通信 ──────────────────────────────
        return try await request(path: "/encounters", method: "GET", authorized: true)
    }

    /// すれ違い送信（POST /encounters）。サーバーの判定結果を返す：
    /// matched_pending（マッチ候補あり）/ recorded（ブロック関係で記録のみ）/ ignored（どちらかがマッチOFF）
    @discardableResult
    func sendEncounter(_ upload: EncounterUpload) async throws -> String {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] sendEncounter → 成功（相手=\(upload.peerUuid.prefix(8))… rssi=\(upload.rssi.map(String.init) ?? "-"))")
            return "matched_pending"
        }

        // ── 本番通信 ──────────────────────────────
        let result: SimpleStatus = try await request(path: "/encounters", method: "POST", body: upload, authorized: true)
        return result.status
    }

    /// マッチ承認（POST /matches/{uuid}/approve）。
    /// 返り値は pending（相手の承認待ち）または approved（双方承認でSNS開示）。
    @discardableResult
    func approveMatch(peerUuid: String) async throws -> MatchStatus {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] approveMatch → 成功（相手=\(peerUuid)）")
            return MockData.approveLocally(uuid: peerUuid)
        }

        // ── 本番通信 ──────────────────────────────
        let result: SimpleStatus = try await request(path: "/matches/\(peerUuid)/approve", method: "POST", authorized: true)
        return MatchStatus(rawValue: result.status) ?? .pending
    }

    /// マッチ拒否（POST /matches/{uuid}/reject）
    func rejectMatch(peerUuid: String) async throws {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] rejectMatch → 成功（相手=\(peerUuid)）")
            MockData.rejectLocally(uuid: peerUuid)
            return
        }

        // ── 本番通信 ──────────────────────────────
        try await requestVoid(path: "/matches/\(peerUuid)/reject", method: "POST", authorized: true)
    }

    // MARK: - ブロック

    /// ブロック追加（POST /blocklist）
    func blockUser(uuid: String) async throws {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] blockUser → 成功（相手=\(uuid)）")
            MockData.blockLocally(uuid: uuid)
            return
        }

        // ── 本番通信 ──────────────────────────────
        let body = BlockRequest(targetUuid: uuid)
        try await requestVoid(path: "/blocklist", method: "POST", body: body, authorized: true)
    }

    /// ブロック中の一覧（GET /blocklist）
    func fetchBlocklist() async throws -> [BlockedUser] {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] fetchBlocklist → ダミー\(MockData.blockedUsers.count)件返却")
            return MockData.blockedUsers
        }

        // ── 本番通信 ──────────────────────────────
        return try await request(path: "/blocklist", method: "GET", authorized: true)
    }

    /// ブロック解除（DELETE /blocklist/{uuid}）
    func unblockUser(uuid: String) async throws {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] unblockUser → 成功（相手=\(uuid)）")
            MockData.unblockLocally(uuid: uuid)
            return
        }

        // ── 本番通信 ──────────────────────────────
        try await requestVoid(path: "/blocklist/\(uuid)", method: "DELETE", authorized: true)
    }

    // MARK: - マップピン

    func fetchMapPins() async throws -> [MapPin] {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] fetchMapPins → ダミー\(MockData.mapPins.count)件返却")
            return MockData.mapPins
        }

        // ── 本番通信 ──────────────────────────────
        return try await request(path: "/map_pins", method: "GET", authorized: true)
    }

    func createMapPin(message: String, latitude: Double, longitude: Double) async throws -> MapPin {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] createMapPin → 成功（\(message)）")
            let pin = MapPin(
                id: Int.random(in: 1000...9999),
                message: message,
                latitude: latitude,
                longitude: longitude,
                createdAt: Date(),
                isMine: true
            )
            MockData.addPinLocally(pin)
            return pin
        }

        // ── 本番通信 ──────────────────────────────
        let body = MapPinCreate(message: message, latitude: latitude, longitude: longitude)
        return try await request(path: "/map_pins", method: "POST", body: body, authorized: true)
    }

    /// ピン1件（GET /map_pins/{id}）。期限切れ・削除済みは 404。
    func fetchMapPin(id: Int) async throws -> MapPin {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] fetchMapPin → id=\(id)")
            guard let pin = MockData.mapPins.first(where: { $0.id == id }) else {
                throw APIError.server(status: 404, message: #"{"detail":"ピンが見つかりません"}"#)
            }
            return pin
        }

        // ── 本番通信 ──────────────────────────────
        return try await request(path: "/map_pins/\(id)", method: "GET", authorized: true)
    }

    /// ピン更新（PATCH /map_pins/{id}）。自分のピン以外は 403。
    func updateMapPin(id: Int, _ update: MapPinUpdate) async throws -> MapPin {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] updateMapPin → id=\(id)")
            return try MockData.updatePinLocally(id: id, update)
        }

        // ── 本番通信 ──────────────────────────────
        return try await request(path: "/map_pins/\(id)", method: "PATCH", body: update, authorized: true)
    }

    /// ピン削除（DELETE /map_pins/{id}）。自分のピン以外は 403。
    func deleteMapPin(id: Int) async throws {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] deleteMapPin → id=\(id)")
            MockData.deletePinLocally(id: id)
            return
        }

        // ── 本番通信 ──────────────────────────────
        try await requestVoid(path: "/map_pins/\(id)", method: "DELETE", authorized: true)
    }

    // MARK: - ヘルスチェック

    @discardableResult
    func healthCheck() async throws -> String {
        if settings.useMock {
            await mockDelay()
            print("[MOCK] healthCheck → mock: ok")
            return "mock: ok"
        }

        // ── 本番通信 ──────────────────────────────
        guard let url = baseURL?.appendingPathComponent("health") else { throw APIError.invalidURL }
        let (data, response) = try await Self.session.data(from: url)
        try validate(response, data: data, authorized: false)
        return String(data: data, encoding: .utf8) ?? "ok"
    }

    // MARK: - 汎用リクエスト（本番通信の共通処理）

    private func request<T: Decodable>(
        path: String,
        method: String,
        authorized: Bool
    ) async throws -> T {
        try await request(path: path, method: method, body: Optional<Int>.none, authorized: authorized)
    }

    private func request<T: Decodable, B: Encodable>(
        path: String,
        method: String,
        body: B?,
        authorized: Bool
    ) async throws -> T {
        let (data, response) = try await perform(path: path, method: method, body: body, authorized: authorized)
        try validate(response, data: data, authorized: authorized)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    private func requestVoid<B: Encodable>(
        path: String,
        method: String,
        body: B? = Optional<Int>.none,
        authorized: Bool
    ) async throws {
        let (data, response) = try await perform(path: path, method: method, body: body, authorized: authorized)
        try validate(response, data: data, authorized: authorized)
    }

    private func perform<B: Encodable>(
        path: String,
        method: String,
        body: B?,
        authorized: Bool
    ) async throws -> (Data, URLResponse) {
        guard let url = baseURL?.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path) else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if authorized {
            guard let token = authToken else { throw APIError.notAuthenticated }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            req.httpBody = try Self.encoder.encode(body)
        }

        do {
            return try await Self.session.data(for: req)
        } catch {
            throw APIError.underlying(error.localizedDescription)
        }
    }

    private func validate(_ response: URLResponse, data: Data, authorized: Bool) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            // ログイン失敗の 401 は対象外（authorized=false）。トークンが通らなくなったときだけログアウトさせる
            if authorized && http.statusCode == 401 {
                onUnauthorized?()
            }
            let message = String(data: data, encoding: .utf8)
            throw APIError.server(status: http.statusCode, message: message)
        }
    }
}
