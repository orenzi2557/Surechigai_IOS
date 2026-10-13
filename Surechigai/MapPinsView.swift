//
//  MapPinsView.swift
//  Surechigai
//
//  マップ画面。2つのレイヤーを切り替えて表示する:
//   ・すれ違い … 実際にすれ違った地点（/encounters の緯度経度）
//   ・ひとこと … 匿名マップピン（/map_pins。モックではローカル追加）
//                ピンをタップすると詳細（GET /map_pins/{id}）を開き、自分のピン（is_mine）なら編集(PATCH)・削除(DELETE)ができる
//

import SwiftUI
import MapKit

/// 匿名マップピン
struct MapPin: Identifiable, Hashable, Codable {
    let id: Int
    let message: String
    let latitude: Double
    let longitude: Double
    let createdAt: Date
    /// 自分が投稿したピンか（is_mine）。ピンは匿名なので投稿者は返らず、これで編集・削除できるかを判断する
    let isMine: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension MapPin {
    private enum CodingKeys: String, CodingKey {
        case id, message, latitude, longitude, createdAt, isMine
    }

    /// is_mine が無い古いサーバーでも読めるようにする（その場合は他人のピン扱い）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        message = try c.decode(String.self, forKey: .message)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        isMine = try c.decodeIfPresent(Bool.self, forKey: .isMine) ?? false
    }
}

/// 地図に重ねるレイヤー
private enum MapLayer: String, CaseIterable, Identifiable {
    case encounters = "すれ違い"
    case pins = "ひとこと"
    var id: String { rawValue }
}

struct MapPinsView: View {
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var zoneStore: ZoneStore

    @State private var layer: MapLayer = .encounters
    @State private var pins: [MapPin] = []
    @State private var encounters: [EncounterResponse] = []
    @State private var selectedEncounter: EncounterResponse?
    @State private var selectedPin: MapPin?
    @State private var showAdd = false
    @State private var errorMessage: String?
    /// 地図の現在の中心（投稿位置に使う）
    @State private var currentCenter = CLLocationCoordinate2D(latitude: 35.6705, longitude: 139.7027)
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 35.6705, longitude: 139.7027),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
    )

    /// 緯度経度を持つすれ違いのみ
    private var locatedEncounters: [EncounterResponse] {
        encounters.filter { $0.latitude != nil && $0.longitude != nil }
    }

    /// 地図に置くマーカー。近すぎるものは少しずらして重なりを防ぐ。
    private var encounterMarkers: [EncounterMarker] {
        var result: [EncounterMarker] = []
        for group in Self.clustered(locatedEncounters) {
            guard group.count > 1 else {
                if let e = group.first {
                    result.append(EncounterMarker(encounter: e, coordinate: e.coordinate))
                }
                continue
            }
            // 同じ場所で何度もすれ違うため、実データではピンがほぼ重なる。
            // 中心のまわりに等間隔で並べて、全員タップできるようにする。
            let centerLat = group.map { $0.coordinate.latitude }.reduce(0, +) / Double(group.count)
            let centerLon = group.map { $0.coordinate.longitude }.reduce(0, +) / Double(group.count)
            let radius = 0.00022                                   // 緯度で約25m
            let lonScale = max(cos(centerLat * .pi / 180), 0.1)    // 経度は緯度により縮む
            for (i, e) in group.enumerated() {
                let angle = (2 * Double.pi / Double(group.count)) * Double(i) - .pi / 2
                result.append(EncounterMarker(
                    encounter: e,
                    coordinate: CLLocationCoordinate2D(
                        latitude: centerLat + radius * sin(angle),
                        longitude: centerLon + radius * cos(angle) / lonScale
                    )
                ))
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    /// 近接するすれ違いをまとめる（しきい値以内なら同じ塊とみなす）
    private static func clustered(
        _ items: [EncounterResponse],
        thresholdMeters: Double = 60
    ) -> [[EncounterResponse]] {
        var groups: [[EncounterResponse]] = []
        for item in items {
            let location = CLLocation(latitude: item.coordinate.latitude, longitude: item.coordinate.longitude)
            let index = groups.firstIndex { group in
                group.contains { other in
                    location.distance(from: CLLocation(
                        latitude: other.coordinate.latitude,
                        longitude: other.coordinate.longitude
                    )) < thresholdMeters
                }
            }
            if let index {
                groups[index].append(item)
            } else {
                groups.append([item])
            }
        }
        return groups
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                map
                    .ignoresSafeArea(edges: .top)

                layerPicker

                VStack {
                    Spacer()
                    bottomContent
                }
            }
            .navigationTitle("マップ")
            .navigationBarTitleDisplayMode(.inline)
            .alert("エラー", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .toolbar {
                if layer == .pins {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAdd = true } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddPinView { message in
                    addPin(message: message)
                }
                .presentationDetents([.medium])
            }
            .sheet(item: $selectedPin) { pin in
                PinDetailView(pinID: pin.id, mapCenter: currentCenter) { change in
                    applyPinChange(id: pin.id, change)
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $selectedEncounter) { enc in
                NavigationStack {
                    EncounterDetailView(encounter: enc) {
                        Task { await load() }
                    }
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("閉じる") { selectedEncounter = nil }
                            }
                        }
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .onChange(of: layer) { _, newValue in recenter(for: newValue) }
        }
    }

    // MARK: - 地図

    private var map: some View {
        Map(position: $position) {
            // マッチしない場所（自分だけに見える。サーバーには送っていない）
            ForEach(zoneStore.zones.filter(\.isEnabled)) { zone in
                MapCircle(center: zone.coordinate, radius: zone.radius)
                    .foregroundStyle(Color.orange.opacity(0.15))
                    .stroke(Color.orange, lineWidth: 1.5)
            }
            switch layer {
            case .encounters:
                ForEach(encounterMarkers) { marker in
                    Annotation(marker.encounter.peerDisplayName, coordinate: marker.coordinate) {
                        Button {
                            selectedEncounter = marker.encounter
                        } label: {
                            encounterMarker(marker.encounter)
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .pins:
                ForEach(pins) { pin in
                    Annotation(pin.message, coordinate: pin.coordinate) {
                        Button {
                            selectedPin = pin
                        } label: {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title)
                                .foregroundStyle(pin.isMine ? Color.brandAccent : Color.brandPrimary)
                                .background(Circle().fill(.white).padding(3))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onMapCameraChange { context in
            currentCenter = context.region.center
        }
    }

    private func encounterMarker(_ enc: EncounterResponse) -> some View {
        Image(systemName: "figure.2.arms.open")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .padding(8)
            .background(
                Circle().fill(enc.status == .approved ? Color.brandAccent : Color.brandSecondary)
            )
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }

    // MARK: - レイヤー切り替え

    private var layerPicker: some View {
        Picker("レイヤー", selection: $layer) {
            ForEach(MapLayer.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - 下部のカード

    @ViewBuilder
    private var bottomContent: some View {
        switch layer {
        case .encounters:
            if locatedEncounters.isEmpty {
                emptyHint("すれ違った地点はまだありません")
            } else {
                encounterList
            }
        case .pins:
            if pins.isEmpty {
                emptyHint("まだピンがありません。右上の＋で投稿できます")
            } else {
                pinList
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 20)
    }

    private var encounterList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(locatedEncounters) { enc in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Avatar(name: enc.peerDisplayName, url: enc.peerProfileImageUrl, size: 32)
                            Text(enc.peerDisplayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.brandInk)
                                .lineLimit(1)
                        }
                        StatusBadge(status: enc.status)
                        Text(enc.detectedAt.relativeString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 180, alignment: .leading)
                    .card(padding: 14)
                    .onTapGesture {
                        focus(on: markerCoordinate(for: enc))
                        selectedEncounter = enc
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var pinList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(pins) { pin in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pin.message)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.brandInk)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if pin.isMine {
                                Text("自分")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.brandAccent))
                            }
                            Text(pin.createdAt.relativeString)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 180, alignment: .leading)
                    .card(padding: 14)
                    .onTapGesture {
                        focus(on: pin.coordinate)
                        selectedPin = pin
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    // MARK: - ロジック

    private func load() async {
        do {
            async let pinsResult = api.fetchMapPins()
            async let encountersResult = api.fetchEncounters()
            pins = try await pinsResult.sorted { $0.createdAt > $1.createdAt }
            encounters = try await encountersResult.sorted { $0.detectedAt > $1.detectedAt }
            recenter(for: layer)
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 表示中レイヤーの地点が収まるよう地図を寄せる
    private func recenter(for layer: MapLayer) {
        let coords: [CLLocationCoordinate2D]
        switch layer {
        case .encounters: coords = encounterMarkers.map(\.coordinate)
        case .pins:       coords = pins.map(\.coordinate)
        }
        guard let region = Self.region(fitting: coords) else { return }
        withAnimation { position = .region(region) }
    }

    /// カードに対応するマーカーの位置（ずらし後）
    private func markerCoordinate(for encounter: EncounterResponse) -> CLLocationCoordinate2D {
        encounterMarkers.first { $0.id == encounter.id }?.coordinate ?? encounter.coordinate
    }

    private func focus(on coordinate: CLLocationCoordinate2D) {
        withAnimation {
            position = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
        }
    }

    /// 座標群を包含する地図領域を計算する（少し余白を持たせる）
    private static func region(fitting coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.02),
            longitudeDelta: max((maxLon - minLon) * 1.5, 0.02)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    /// 詳細画面での編集・削除を一覧に反映する
    private func applyPinChange(id: Int, _ change: PinChange) {
        withAnimation {
            switch change {
            case .updated(let pin):
                if let i = pins.firstIndex(where: { $0.id == id }) { pins[i] = pin }
            case .removed:
                pins.removeAll { $0.id == id }
            }
        }
    }

    /// 地図の現在の中心にピンを投稿する（モック時はローカル、本番時はサーバーへ）
    private func addPin(message: String) {
        Task {
            do {
                let pin = try await api.createMapPin(
                    message: message,
                    latitude: currentCenter.latitude,
                    longitude: currentCenter.longitude
                )
                withAnimation { pins.insert(pin, at: 0) }
            } catch {
                errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// 地図上の1マーカー。重なり回避で実座標からずらすことがある。
private struct EncounterMarker: Identifiable {
    let encounter: EncounterResponse
    let coordinate: CLLocationCoordinate2D
    var id: Int { encounter.id }
}

/// すれ違いの座標（緯度経度が両方あるときのみ有効）
private extension EncounterResponse {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude ?? 0, longitude: longitude ?? 0)
    }
}

private struct AddPinView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    let onSubmit: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("この場所にひとことを残せます（匿名）")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("例: ここでよくすれ違う☕️", text: $message, axis: .vertical)
                    .lineLimit(3...5)
                    .padding(12)
                    .background(Color.appBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button("ピンを投稿") {
                    onSubmit(message)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle(enabled: !message.trimmingCharacters(in: .whitespaces).isEmpty))
                .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .padding(20)
            .navigationTitle("ピンを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

// MARK: - ピン詳細（取得・編集・削除）

/// 詳細画面から一覧へ伝える変更
enum PinChange {
    case updated(MapPin)
    /// 削除した、または期限切れ・削除済みで取得できなかった
    case removed
}

/// ピン1件の詳細。GET /map_pins/{id} で最新を取り直し、PATCH / DELETE を行う。
/// 編集・削除は自分のピン（is_mine）のときだけ出す。サーバーも他人のピンは 403 で断る。
private struct PinDetailView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss

    let pinID: Int
    /// 「地図の中心に移動」で使う、詳細を開いた時点の地図中心
    let mapCenter: CLLocationCoordinate2D
    let onChange: (PinChange) -> Void

    @State private var pin: MapPin?
    @State private var draft = ""
    @State private var moveToCenter = false
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasChanges: Bool {
        guard let pin else { return false }
        return (!trimmedDraft.isEmpty && trimmedDraft != pin.message) || moveToCenter
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if isLoading {
                        ProgressView().padding(.top, 40)
                    } else if let pin {
                        infoCard(pin)
                        if pin.isMine {
                            editCard
                            deleteButton
                        } else {
                            othersPinNote
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("ピンの詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
            }
            .confirmationDialog("このピンを削除しますか？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("削除する", role: .destructive) { Task { await delete() } }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("削除すると元に戻せません。")
            }
            .task { await load() }
        }
    }

    private func infoCard(_ pin: MapPin) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "ひとこと", systemImage: "mappin.and.ellipse")
            Text(pin.message)
                .font(.body)
                .foregroundStyle(Color.brandInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            InfoRow(label: "投稿", value: pin.createdAt.formatted(date: .abbreviated, time: .shortened))
            InfoRow(label: "地点", value: String(format: "%.5f, %.5f", pin.latitude, pin.longitude), mono: true)
            InfoRow(label: "ID", value: "\(pin.id)", mono: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var editCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "編集", systemImage: "pencil")
            TextField("ひとこと", text: $draft, axis: .vertical)
                .lineLimit(2...4)
                .padding(12)
                .background(Color.appBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Toggle(isOn: $moveToCenter) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("位置を地図の中心に移動").font(.subheadline)
                    Text(String(format: "%.5f, %.5f", mapCenter.latitude, mapCenter.longitude))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Color.brandPrimary)
            Button {
                Task { await save() }
            } label: {
                if isWorking { ProgressView().tint(.white) } else { Text("保存") }
            }
            .buttonStyle(PrimaryButtonStyle(enabled: hasChanges))
            .disabled(!hasChanges || isWorking)
        }
        .card()
    }

    private var othersPinNote: some View {
        Label("ほかの人のピンは編集・削除できません", systemImage: "lock")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label("ピンを削除", systemImage: "trash")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.red.opacity(0.1))
                .foregroundStyle(.red)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .disabled(isWorking)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await api.fetchMapPin(id: pinID)
            pin = fetched
            draft = fetched.message
            onChange(.updated(fetched))
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            // 期限切れ・削除済みなら一覧からも外す
            if (error as? APIError)?.statusCode == 404 { onChange(.removed) }
        }
    }

    private func save() async {
        guard let pin else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        var update = MapPinUpdate()
        if !trimmedDraft.isEmpty && trimmedDraft != pin.message { update.message = trimmedDraft }
        if moveToCenter {
            update.latitude = mapCenter.latitude
            update.longitude = mapCenter.longitude
        }
        do {
            let updated = try await api.updateMapPin(id: pin.id, update)
            self.pin = updated
            draft = updated.message
            moveToCenter = false
            onChange(.updated(updated))
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func delete() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await api.deleteMapPin(id: pinID)
            onChange(.removed)
            dismiss()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
