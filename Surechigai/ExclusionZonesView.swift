//
//  ExclusionZonesView.swift
//  Surechigai
//
//  マッチしない場所（自宅・学校・職場など）の一覧と登録。
//  範囲内にいる間は発信も受信も止まり、すれ違いは記録されない。座標は端末内だけに保存する。
//

import SwiftUI
import MapKit
import CoreLocation

struct ExclusionZonesView: View {
    @EnvironmentObject private var zoneStore: ZoneStore
    @EnvironmentObject private var ble: BLEManager

    @State private var editing: ExclusionZone?
    @State private var showAdd = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard

                if zoneStore.zones.isEmpty {
                    EmptyStateView(
                        systemImage: "house.and.flag",
                        title: "まだ登録がありません",
                        message: "右上の＋から、自宅や職場など\nすれ違いたくない場所を登録できます"
                    )
                    .card()
                } else {
                    ForEach(zoneStore.zones) { zone in
                        zoneRow(zone)
                    }
                }

                Text("位置は端末の中だけに保存され、サーバーには送られません。裏にいる間も判定できるよう、位置情報は「常に許可」をおすすめします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("マッチしない場所")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
            }
        }
        .sheet(isPresented: $showAdd) {
            ZoneEditorView(zone: nil, initialCenter: ble.lastLocation?.coordinate) { zone in
                zoneStore.add(zone)
            }
        }
        .sheet(item: $editing) { zone in
            ZoneEditorView(zone: zone, initialCenter: nil, onSave: { zoneStore.update($0) },
                           onDelete: { zoneStore.remove(id: zone.id) })
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: ble.activeZone == nil ? "dot.radiowaves.left.and.right" : "pause.circle.fill")
                .font(.title2)
                .foregroundStyle(ble.activeZone == nil ? Color.brandAccent : .orange)
            VStack(alignment: .leading, spacing: 2) {
                if let zone = ble.activeZone {
                    Text("「\(zone.name)」の中にいます").font(.subheadline.weight(.semibold))
                    Text("発信・受信を停止中。すれ違いは記録されません").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("マッチしない場所の外にいます").font(.subheadline.weight(.semibold))
                    Text(locationNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .card()
    }

    private var locationNote: String {
        switch ble.locationAuthorization {
        case .authorizedAlways:    return "位置情報: 常に許可（裏にいても判定します）"
        case .authorizedWhenInUse: return "位置情報: 使用中のみ（裏にいる間は判定が遅れます）"
        case .denied, .restricted: return "位置情報が許可されていないため判定できません"
        default:                   return "位置情報: 未確認"
        }
    }

    private func zoneRow(_ zone: ExclusionZone) -> some View {
        HStack(spacing: 12) {
            Image(systemName: zone.kind.symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(zone.isEnabled ? Color.brandPrimary : Color.gray.opacity(0.5)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(zone.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.brandInk)
                    if ble.activeZone?.id == zone.id {
                        Text("いまここ")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                Text("\(zone.kind.label)・半径\(Int(zone.radius))m")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { zone.isEnabled },
                set: { zoneStore.setEnabled(zone.id, $0) }
            ))
            .labelsHidden()
            .tint(Color.brandPrimary)
        }
        .card(padding: 14)
        .contentShape(Rectangle())
        .onTapGesture { editing = zone }
    }
}

// MARK: - 登録・編集

private struct ZoneEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let original: ExclusionZone?
    let onSave: (ExclusionZone) -> Void
    var onDelete: (() -> Void)?

    @State private var name: String
    @State private var kind: ExclusionZone.Kind
    @State private var radius: Double
    @State private var center: CLLocationCoordinate2D
    @State private var position: MapCameraPosition

    init(zone: ExclusionZone?, initialCenter: CLLocationCoordinate2D?,
         onSave: @escaping (ExclusionZone) -> Void, onDelete: (() -> Void)? = nil) {
        self.original = zone
        self.onSave = onSave
        self.onDelete = onDelete
        let start = zone?.coordinate ?? initialCenter ?? CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671)
        _name = State(initialValue: zone?.name ?? "")
        _kind = State(initialValue: zone?.kind ?? .home)
        _radius = State(initialValue: zone?.radius ?? 200)
        _center = State(initialValue: start)
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: start, latitudinalMeters: 1500, longitudinalMeters: 1500
        )))
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? kind.label : trimmed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    mapCard
                    formCard
                    if onDelete != nil {
                        Button(role: .destructive) {
                            onDelete?()
                            dismiss()
                        } label: {
                            Label("この場所を削除", systemImage: "trash")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.red.opacity(0.1))
                                .foregroundStyle(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle(original == nil ? "場所を追加" : "場所を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        var zone = original ?? ExclusionZone(
                            name: displayName, kind: kind,
                            latitude: center.latitude, longitude: center.longitude, radius: radius
                        )
                        zone.name = displayName
                        zone.kind = kind
                        zone.latitude = center.latitude
                        zone.longitude = center.longitude
                        zone.radius = radius
                        onSave(zone)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    /// 地図を動かして中心（十字）を合わせる
    private var mapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Map(position: $position) {
                    MapCircle(center: center, radius: radius)
                        .foregroundStyle(Color.brandPrimary.opacity(0.18))
                        .stroke(Color.brandPrimary, lineWidth: 2)
                    UserAnnotation()
                }
                .onMapCameraChange(frequency: .continuous) { context in
                    center = context.region.center
                }
                Image(systemName: "plus")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.brandPrimary)
                    .allowsHitTesting(false)
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack {
                Text(String(format: "%.5f, %.5f", center.latitude, center.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    position = .userLocation(fallback: position)
                } label: {
                    Label("現在地", systemImage: "location.fill").font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(Color.brandPrimary)
            }
            Text("地図を動かして、十字を場所の中心に合わせてください")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("種類", selection: $kind) {
                ForEach(ExclusionZone.Kind.allCases) { k in
                    Label(k.label, systemImage: k.symbol).tag(k)
                }
            }
            .pickerStyle(.segmented)

            TextField("名前（未入力なら「\(kind.label)」）", text: $name)
                .padding(12)
                .background(Color.appBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("半径").font(.subheadline)
                    Spacer()
                    Text("\(Int(radius)) m").font(.subheadline.monospacedDigit()).foregroundStyle(Color.brandPrimary)
                }
                Slider(value: $radius, in: 50...1000, step: 50)
                    .tint(Color.brandPrimary)
                Text("広めにしておくと、位置情報の誤差があっても確実に止まります")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }
}
