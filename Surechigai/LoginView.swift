//
//  LoginView.swift
//  Surechigai
//
//  ログイン / 新規登録画面。サーバー設定（モードトグル・IP欄）を含む。
//

import SwiftUI
import UIKit

struct LoginView: View {

    enum Mode: String, CaseIterable {
        case login = "ログイン"
        case register = "新規登録"
    }

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var session: SessionStore

    @State private var mode: Mode = .login
    @State private var loginId = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var tags: [String] = []
    @State private var newTag = ""

    @State private var isLoading = false
    @State private var errorMessage: String?

    /// 登録時にすぐ選べる候補。自由入力もできる。
    private let suggestedTags = ["カフェ", "音楽", "映画", "読書", "写真", "散歩", "ランニング", "ゲーム", "旅行", "料理"]

    var body: some View {
        ZStack {
            LinearGradient.brandSoft.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    header
                    formCard
                    serverCard
                }
                .padding(20)
                .padding(.top, 30)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: ヘッダー

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient.brand)
                    .frame(width: 92, height: 92)
                    .shadow(color: Color.brandPrimary.opacity(0.4), radius: 16, x: 0, y: 8)
                Image(systemName: "figure.2.arms.open")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("すれ違い")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Color.brandInk)
            Text("今日、誰かとすれ違う。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    // MARK: 入力フォーム

    private var formCard: some View {
        VStack(spacing: 18) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if mode == .register {
                LabeledField(icon: "person.text.rectangle", title: "表示名（任意）") {
                    TextField("例: たろう", text: $displayName)
                        .textInputAutocapitalization(.never)
                }
                tagsSection
            }

            LabeledField(icon: "at", title: "ログインID") {
                TextField("ログインID", text: $loginId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            LabeledField(icon: "lock", title: "パスワード") {
                SecureField("パスワード", text: $password)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let reason = session.signOutReason {
                Label(reason, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: submit) {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(mode == .login ? "ログイン" : "アカウント作成")
                }
            }
            .buttonStyle(PrimaryButtonStyle(enabled: canSubmit))
            .disabled(!canSubmit || isLoading)

            if settings.useMock {
                Label("モックモード中：任意のID・パスワードでログインできます", systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(Color.brandPrimary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
        }
        .card()
    }

    /// 趣味タグ（登録時）。候補タップ＋自由入力の両方に対応する。
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("趣味タグ（任意）")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("あとからプロフィールで変更できます")
                .font(.caption2)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 8) {
                ForEach(suggestedTags, id: \.self) { tag in
                    TagChip(text: tag, selected: tags.contains(tag))
                        .onTapGesture { toggleTag(tag) }
                }
            }

            // 候補以外に自分で追加したタグ
            let extras = tags.filter { !suggestedTags.contains($0) }
            if !extras.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(extras, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag).font(.subheadline)
                            Image(systemName: "xmark.circle.fill").font(.caption)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.brandPrimary.opacity(0.1))
                        .foregroundStyle(Color.brandPrimary)
                        .clipShape(Capsule())
                        .onTapGesture { tags.removeAll { $0 == tag } }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("その他のタグを追加", text: $newTag)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(Color.appBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button {
                    addTag()
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleTag(_ tag: String) {
        if let i = tags.firstIndex(of: tag) {
            tags.remove(at: i)
        } else {
            tags.append(tag)
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
        newTag = ""
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
        tags.append(trimmed)
    }

    // MARK: サーバー設定

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "サーバー設定", systemImage: "server.rack")

            Toggle(isOn: $settings.useMock) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("モックモード（サーバー不要）")
                        .font(.subheadline.weight(.medium))
                    Text("サーバーに接続せずダミーデータで動作します")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color.appBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            // モックON時はIP欄をグレーアウト
            .opacity(settings.useMock ? 0.45 : 1)
            .disabled(settings.useMock)
        }
        .card()
    }

    // MARK: ロジック

    private var canSubmit: Bool {
        !loginId.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty
    }

    private func submit() {
        // キーボードを閉じてから処理（フォーカス起因の画面更新遅延を防ぐ）
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        errorMessage = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let auth: AuthResponse
                switch mode {
                case .login:
                    auth = try await api.login(loginId: loginId, password: password)
                case .register:
                    auth = try await api.register(
                        loginId: loginId,
                        password: password,
                        displayName: displayName,
                        tags: tags
                    )
                }
                session.signIn(token: auth.accessToken, uuid: auth.uuid)
            } catch {
                errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - ラベル付き入力欄

private struct LabeledField<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(Color.brandPrimary)
                    .frame(width: 20)
                content
            }
            .padding(13)
            .background(Color.appBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
