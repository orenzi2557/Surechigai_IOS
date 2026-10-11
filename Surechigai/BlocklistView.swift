//
//  BlocklistView.swift
//  Surechigai
//
//  ブロック中のユーザー一覧。設定画面から開く。解除もここで行う。
//

import SwiftUI

struct BlocklistView: View {
    @EnvironmentObject private var api: APIClient

    @State private var blocked: [BlockedUser] = []
    @State private var isLoading = false
    @State private var workingUuid: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                }

                if blocked.isEmpty && !isLoading {
                    EmptyStateView(
                        systemImage: "hand.raised.slash",
                        title: "ブロック中のユーザーはいません",
                        message: "相手の詳細画面の「…」からブロックできます"
                    )
                    .card()
                } else {
                    ForEach(blocked) { user in
                        row(user)
                    }
                }
            }
            .padding(20)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("ブロック中のユーザー")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isLoading {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ user: BlockedUser) -> some View {
        HStack(spacing: 12) {
            Avatar(name: user.displayName, url: nil, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.brandInk)
                Text(user.uuid)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await unblock(user) }
            } label: {
                if workingUuid == user.uuid {
                    ProgressView().controlSize(.small)
                } else {
                    Text("解除")
                }
            }
            .buttonStyle(.bordered)
            .tint(Color.brandPrimary)
            .disabled(workingUuid != nil)
        }
        .card()
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            blocked = try await api.fetchBlocklist()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func unblock(_ user: BlockedUser) async {
        workingUuid = user.uuid
        errorMessage = nil
        defer { workingUuid = nil }
        do {
            try await api.unblockUser(uuid: user.uuid)
            withAnimation { blocked.removeAll { $0.uuid == user.uuid } }
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
