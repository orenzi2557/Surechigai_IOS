//
//  ProfileView.swift
//  Surechigai
//
//  自分のプロフィール表示。
//

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var session: SessionStore

    @State private var user: UserResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showEdit = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let user {
                        headerCard(user)
                        if let bio = user.bio, !bio.isEmpty {
                            bioCard(bio)
                        }
                        tagsCard(user)
                        snsCard(user)
                        detailCard(user)
                    } else if isLoading {
                        ProgressView().padding(.top, 60)
                    } else if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red).card()
                    }
                }
                .padding(20)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("プロフィール")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("編集") { showEdit = true }
                        .disabled(user == nil)
                }
            }
            .task { await load() }
            .sheet(isPresented: $showEdit) {
                if let user {
                    EditProfileView(user: user) { updated in
                        self.user = updated
                        session.currentUser = updated
                    }
                }
            }
        }
    }

    private func headerCard(_ user: UserResponse) -> some View {
        VStack(spacing: 12) {
            Avatar(name: user.displayName, url: user.profileImageUrl, size: 100)
            Text(user.displayName)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Text("@\(user.loginId)")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(LinearGradient.brand)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.cardCorner, style: .continuous))
        .shadow(color: Color.brandPrimary.opacity(0.3), radius: 14, x: 0, y: 8)
    }

    private func bioCard(_ bio: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "自己紹介", systemImage: "text.quote")
            Text(bio).font(.subheadline).foregroundStyle(Color.brandInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func tagsCard(_ user: UserResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "趣味タグ", systemImage: "tag")
            if user.tags.isEmpty {
                Text("タグが未設定です").font(.subheadline).foregroundStyle(.secondary)
            } else {
                FlowTags(tags: user.tags)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func snsCard(_ user: UserResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "SNSリンク", systemImage: "link")
            if user.snsLinks.isEmpty {
                Text("SNSが未設定です").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(user.snsLinks) { link in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(Color.brandPrimary)
                        Text(link.platform).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(link.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func detailCard(_ user: UserResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "基本情報", systemImage: "person.text.rectangle")
            InfoRow(label: "UUID", value: user.uuid, mono: true)
            if let age = user.age { InfoRow(label: "年齢", value: "\(age)") }
            if let gender = user.gender { InfoRow(label: "性別", value: gender) }
            InfoRow(label: "マッチ", value: user.matchEnabled ? "受付中" : "オフ")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let me = try await api.fetchMe()
            user = me
            session.currentUser = me
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
