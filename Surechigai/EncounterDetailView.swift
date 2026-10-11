//
//  EncounterDetailView.swift
//  Surechigai
//
//  すれ違った相手の詳細・マッチ承認画面。
//  双方が承認すると（approved）SNSリンクが開示される。
//  表示時に GET /users/{uuid} で相手の最新プロフィール（年齢・性別・SNSを含む）を取り直す。
//

import SwiftUI

struct EncounterDetailView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss

    let encounter: EncounterResponse
    /// 承認/見送り/ブロックで状態が変わったとき、呼び出し元に一覧の再取得を促す
    var onUpdated: (() -> Void)?

    @State private var status: MatchStatus
    @State private var approvedByMe: Bool
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showBlockConfirm = false
    @State private var isBlocked = false
    /// GET /users/{uuid} で取得した最新の公開プロフィール（取得前・失敗時は nil）
    @State private var profile: PublicUserResponse?
    @State private var profileNotice: String?

    init(encounter: EncounterResponse, onUpdated: (() -> Void)? = nil) {
        self.encounter = encounter
        self.onUpdated = onUpdated
        _status = State(initialValue: encounter.status)
        _approvedByMe = State(initialValue: encounter.approvedByMe)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                profileHeader
                if let profileNotice {
                    Label(profileNotice, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(padding: 14)
                }
                if let basic = basicInfo, !basic.isEmpty {
                    basicInfoCard(basic)
                }
                if let bio = displayBio, !bio.isEmpty {
                    bioCard(bio)
                }
                tagsCard
                encounterInfoCard
                switch status {
                case .approved: snsCard
                case .rejected: rejectedCard
                case .pending:  approvalCard
                }
            }
            .padding(20)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadProfile() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showBlockConfirm = true
                    } label: {
                        Label(isBlocked ? "ブロック中" : "この人をブロック", systemImage: "hand.raised.slash")
                    }
                    .disabled(isBlocked || isWorking)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "\(encounter.peerDisplayName) さんをブロックしますか？",
            isPresented: $showBlockConfirm,
            titleVisibility: .visible
        ) {
            Button("ブロックする", role: .destructive) {
                Task { await block() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("お互いのすれ違い一覧に表示されなくなります。設定＞ブロック中のユーザーから解除できます。")
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 12) {
            Avatar(name: displayName, url: profile?.profileImageUrl ?? encounter.peerProfileImageUrl, size: 96)
            Text(displayName)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.brandInk)
            StatusBadge(status: status)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func bioCard(_ bio: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "自己紹介", systemImage: "text.quote")
            Text(bio)
                .font(.subheadline)
                .foregroundStyle(Color.brandInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var tagsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "趣味タグ", systemImage: "tag")
            FlowTags(tags: profile?.tags ?? encounter.peerTags)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var encounterInfoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "すれ違い情報", systemImage: "location")
            InfoRow(label: "日時", value: encounter.detectedAt.formatted(date: .abbreviated, time: .shortened))
            if let rssi = encounter.rssi {
                InfoRow(label: "信号強度", value: "\(rssi) dBm")
            }
            if let lat = encounter.latitude, let lon = encounter.longitude {
                InfoRow(label: "地点", value: String(format: "%.4f, %.4f", lat, lon), mono: true)
            }
            if let method = encounter.detectionMethod {
                InfoRow(label: "検知方式", value: method.uppercased())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var approvalCard: some View {
        VStack(spacing: 14) {
            SectionHeader(title: "マッチ承認", systemImage: "hand.thumbsup")
            Text(approvedByMe
                 ? "あなたは承認済みです。相手の承認を待っています。"
                 : "この人とつながりたいですか？双方が承認するとSNSが開示されます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await reject() }
                } label: {
                    Text("見送る")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.appBackground)
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(isWorking)

                Button {
                    Task { await approve() }
                } label: {
                    if isWorking { ProgressView().tint(.white) }
                    else { Text(approvedByMe ? "承認済み" : "承認する") }
                }
                .buttonStyle(PrimaryButtonStyle(enabled: !approvedByMe))
                .disabled(approvedByMe || isWorking)
            }
        }
        .card()
    }

    /// 見送り済みのときに出すカード。
    /// この状態はサーバー上で両者共有なので、どちらが見送ったかは書かない。
    private var rejectedCard: some View {
        VStack(spacing: 10) {
            SectionHeader(title: "マッチしませんでした", systemImage: "hand.wave")
            Text("どちらかが見送ったため、この相手とはマッチしません。すれ違い一覧からは引き続き確認できます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
        }
        .card()
    }

    private var snsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "SNSリンク", systemImage: "link")
            Text("マッチが成立しました🎉 連絡を取ってみましょう。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // サーバーが null を返しても、デモ用のSNSを相手のものとして出さない。
            // 承認直後は一覧の値(peerSnsLinks)が古いので、取り直したプロフィールを優先する。
            let links = profile?.snsLinks.nilIfEmpty ?? encounter.peerSnsLinks ?? []
            if links.isEmpty {
                Text("相手はSNSリンクを登録していません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(links) { link in
                Link(destination: URL(string: link.url) ?? URL(string: "https://example.com")!) {
                    HStack {
                        Image(systemName: "arrow.up.right.square.fill")
                            .foregroundStyle(Color.brandPrimary)
                        Text(link.platform)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.brandInk)
                        Spacer()
                        Text(link.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(12)
                    .background(Color.appBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func approve() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await api.approveMatch(peerUuid: encounter.peerUuid)
            approvedByMe = true
            // サーバーの判定に従う（双方承認なら approved、相手待ちなら pending）
            if result == .approved {
                withAnimation { status = .approved }
                // 成立した瞬間にSNSが開示されるので、プロフィールを取り直す
                await loadProfile()
            }
            onUpdated?()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            // 相手が見送り済みだとサーバーが409で拒否する。その場合は見送り表示に切り替える。
            if case let .server(status, _)? = error as? APIError, status == 409 {
                withAnimation { self.status = .rejected }
                onUpdated?()
            }
        }
    }

    // MARK: - 公開プロフィール（GET /users/{uuid}）

    private var displayName: String { profile?.displayName ?? encounter.peerDisplayName }
    private var displayBio: String? { profile?.bio ?? encounter.peerBio }

    /// 年齢・性別（すれ違い一覧には含まれず、公開プロフィールでのみ取れる）
    private var basicInfo: [(String, String)]? {
        guard let profile else { return nil }
        var rows: [(String, String)] = []
        if let age = profile.age { rows.append(("年齢", "\(age)歳")) }
        if let gender = profile.gender, !gender.isEmpty { rows.append(("性別", gender)) }
        return rows
    }

    private func basicInfoCard(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "基本情報", systemImage: "person.text.rectangle")
            ForEach(rows, id: \.0) { row in
                InfoRow(label: row.0, value: row.1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func loadProfile() async {
        do {
            profile = try await api.fetchUser(uuid: encounter.peerUuid)
            profileNotice = nil
        } catch {
            if (error as? APIError)?.statusCode == 404 {
                // すれ違っていない／ブロック関係／退会済み、をサーバーは区別せず404で返す
                profileNotice = "最新のプロフィールを取得できませんでした。相手が退会したか、ブロック関係にある可能性があります。"
            } else if !(error is CancellationError) {
                profileNotice = "最新のプロフィールを取得できませんでした: " + ((error as? APIError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func reject() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await api.rejectMatch(peerUuid: encounter.peerUuid)
            withAnimation { status = .rejected }
            onUpdated?()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func block() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await api.blockUser(uuid: encounter.peerUuid)
            isBlocked = true
            onUpdated?()
            dismiss()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - タグの折り返しレイアウト

struct FlowTags: View {
    let tags: [String]
    var selectable: Bool = false
    var selected: Set<String> = []
    var onTap: ((String) -> Void)? = nil

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                TagChip(text: tag, selected: selected.contains(tag))
                    .onTapGesture { onTap?(tag) }
            }
        }
    }
}

/// 簡易フローレイアウト（iOS 16+ Layout API）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var currentRowWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentRowWidth + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentRowWidth = 0
            }
            rows[rows.count - 1].append(size)
            currentRowWidth += size.width + spacing
        }
        let height = rows.reduce(0) { partial, row in
            partial + (row.map(\.height).max() ?? 0) + spacing
        } - spacing
        return CGSize(width: maxWidth == .infinity ? currentRowWidth : maxWidth, height: max(height, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private extension Array {
    /// 空配列なら nil（?? で次の候補にフォールバックさせる用）
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
