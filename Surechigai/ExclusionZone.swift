//
//  ExclusionZone.swift
//  Surechigai
//
//  マッチしない場所（自宅・学校・職場など）。
//  範囲内にいる間は BLE の発信も受信も止め、すれ違いを記録しない。
//  座標は端末内（UserDefaults）だけに保存し、サーバーへは送らない（設計書v5 2.1）。
//

import Foundation
import CoreLocation
import Combine

struct ExclusionZone: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case home, school, work, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .home:   return "自宅"
            case .school: return "学校"
            case .work:   return "職場"
            case .other:  return "その他"
            }
        }
        var symbol: String {
            switch self {
            case .home:   return "house.fill"
            case .school: return "graduationcap.fill"
            case .work:   return "briefcase.fill"
            case .other:  return "mappin.circle.fill"
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var latitude: Double
    var longitude: Double
    /// 半径（メートル）
    var radius: Double
    var isEnabled = true

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// 現在地がこの範囲に入っているか。
    /// 測位の誤差（horizontalAccuracy、最大100m）を半径に足して、止める側に倒して判定する。
    func contains(_ location: CLLocation) -> Bool {
        guard isEnabled else { return false }
        let margin = max(0, min(location.horizontalAccuracy, 100))
        return location.distance(from: CLLocation(latitude: latitude, longitude: longitude)) <= radius + margin
    }

    /// 座標だけで判定する（すれ違いの記録地点のチェック用。誤差は分からないので足さない）
    func contains(latitude lat: Double, longitude lon: Double) -> Bool {
        guard isEnabled else { return false }
        return CLLocation(latitude: lat, longitude: lon)
            .distance(from: CLLocation(latitude: latitude, longitude: longitude)) <= radius
    }
}

/// マッチしない場所の一覧（端末内のみ）
@MainActor
final class ZoneStore: ObservableObject {
    @Published private(set) var zones: [ExclusionZone] = [] {
        didSet { save() }
    }

    private let key = "exclusionZones"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ExclusionZone].self, from: data) {
            zones = decoded
        }
    }

    func add(_ zone: ExclusionZone) { zones.append(zone) }

    func update(_ zone: ExclusionZone) {
        guard let i = zones.firstIndex(where: { $0.id == zone.id }) else { return }
        zones[i] = zone
    }

    func remove(id: UUID) { zones.removeAll { $0.id == id } }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = zones.firstIndex(where: { $0.id == id }) else { return }
        zones[i].isEnabled = on
    }

    /// アカウント削除時に呼ぶ（自宅などの位置を端末に残さない）
    func removeAll() { zones = [] }

    /// 指定地点を含む有効なゾーン
    func zone(containingLatitude lat: Double, longitude lon: Double) -> ExclusionZone? {
        zones.first { $0.contains(latitude: lat, longitude: lon) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(zones) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
