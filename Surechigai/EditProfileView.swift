//
//  EditProfileView.swift
//  Surechigai
//
//  プロフィール編集（表示名・自己紹介・年齢・性別・タグ・アイコン）。
//

import SwiftUI
import PhotosUI

struct EditProfileView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss

    let user: UserResponse
    let onSaved: (UserResponse) -> Void

    @State private var displayName: String
    @State private var bio: String
    @State private var ageText: String
    @State private var gender: String
    @State private var tags: [String]
    @State private var newTag = ""

    @State private var snsLinks: [SNSLink]
    @State private var newSNSPlatform = "X"
    @State private var newSNSURL = ""

    @State private var photoItem: PhotosPickerItem?
    @State private var pickedImageData: Data?

    @State private var isSaving = false
    @State private var errorMessage: String?

    private let genderOptions = ["未設定", "男性", "女性", "その他"]
    private let snsPlatformOptions = ["X", "Instagram", "TikTok", "YouTube", "LINE", "その他"]

    init(user: UserResponse, onSaved: @escaping (UserResponse) -> Void) {
        self.user = user
        self.onSaved = onSaved
        _displayName = State(initialValue: user.displayName)
        _bio = State(initialValue: user.bio ?? "")
        _ageText = State(initialValue: user.age.map(String.init) ?? "")
        _gender = State(initialValue: user.gender ?? "未設定")
        _tags = State(initialValue: user.tags)
        _snsLinks = State(initialValue: user.snsLinks)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    avatarPicker
                    basicCard
                    tagsCard
                    snsCard
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("プロフィール編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(isSaving)
                }
            }
        }
    }

    private var avatarPicker: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let data = pickedImageData, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable().scaledToFill()
                        .frame(width: 100, height: 100)
                        .clipShape(Circle())
                } else {
                    Avatar(name: displayName, url: user.profileImageUrl, size: 100)
                }
                Image(systemName: "camera.fill")
                    .font(.caption)
                    .padding(8)
                    .background(LinearGradient.brand)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
            PhotosPicker("写真を変更", selection: $photoItem, matching: .images)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: photoItem) { _, item in
            Task { await loadPickedImage(item) }
        }
    }

    private var basicCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "基本情報", systemImage: "person.text.rectangle")
            field("表示名") {
                TextField("表示名", text: $displayName)
            }
            field("自己紹介") {
                TextField("自己紹介", text: $bio, axis: .vertical)
                    .lineLimit(3...6)
            }
            field("年齢") {
                TextField("年齢", text: $ageText)
                    .keyboardType(.numberPad)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("性別").font(.caption).foregroundStyle(.secondary)
                Picker("性別", selection: $gender) {
                    ForEach(genderOptions, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .card()
    }

    private var tagsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "趣味タグ", systemImage: "tag")
            if !tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
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
            HStack {
                TextField("タグを追加", text: $newTag)
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
        .card()
    }

    private var snsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "SNSリンク", systemImage: "link")
            Text("マッチが成立した相手にのみ開示されます")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !snsLinks.isEmpty {
                VStack(spacing: 8) {
                    ForEach(snsLinks) { link in
                        HStack(spacing: 10) {
                            Image(systemName: "globe").foregroundStyle(Color.brandPrimary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.platform).font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.brandInk)
                                Text(link.url).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                snsLinks.removeAll { $0.id == link.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color.brandSecondary)
                            }
                        }
                        .padding(10)
                        .background(Color.appBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach(snsPlatformOptions, id: \.self) { p in
                        Button(p) { newSNSPlatform = p }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(newSNSPlatform).font(.subheadline)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.appBackground)
                    .foregroundStyle(Color.brandInk)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                TextField("URL（例: https://x.com/…）", text: $newSNSURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(10)
                    .background(Color.appBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button {
                    addSNSLink()
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .disabled(newSNSURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .card()
    }

    @ViewBuilder
    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
                .padding(10)
                .background(Color.appBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { newTag = ""; return }
        tags.append(trimmed)
        newTag = ""
    }

    private func addSNSLink() {
        let url = newSNSURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        // 同じ platform+url の重複は追加しない
        guard !snsLinks.contains(where: { $0.platform == newSNSPlatform && $0.url == url }) else {
            newSNSURL = ""
            return
        }
        snsLinks.append(SNSLink(platform: newSNSPlatform, url: url))
        newSNSURL = ""
    }

    /// 選んだ時点でリサイズ＋JPEG化しておく（プレビューも送信も同じデータになる）
    private func loadPickedImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let raw = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: raw) else { return }
        guard let prepared = ImageProcessing.prepareForUpload(image) else { return }
        print("[IMAGE] \(raw.count / 1024)KB → \(prepared.count / 1024)KB に圧縮")
        pickedImageData = prepared
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if let data = pickedImageData {
                _ = try await api.uploadImage(data)
            }
            let req = UpdateMeRequest(
                displayName: displayName,
                age: Int(ageText),
                gender: gender,
                bio: bio,
                matchEnabled: nil,
                tags: tags
            )
            let updatedBasic = try await api.updateMe(req)
            // SNSリンクは別エンドポイント。変更有無に関わらず現在の一覧で同期する。
            var finalUser = updatedBasic
            if snsLinks != user.snsLinks {
                let withSNS = try await api.updateSNSLinks(snsLinks)
                finalUser = UserResponse(
                    uuid: updatedBasic.uuid,
                    loginId: updatedBasic.loginId,
                    displayName: updatedBasic.displayName,
                    age: updatedBasic.age,
                    gender: updatedBasic.gender,
                    bio: updatedBasic.bio,
                    profileImageUrl: updatedBasic.profileImageUrl,
                    matchEnabled: updatedBasic.matchEnabled,
                    tags: updatedBasic.tags,
                    snsLinks: withSNS.snsLinks
                )
            }
            onSaved(finalUser)
            dismiss()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
