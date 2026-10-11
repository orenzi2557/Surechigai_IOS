//
//  BLEManager.swift
//  Surechigai
//
//  すれ違い検知の中核。CoreBluetooth で相手のUUIDを受信し、
//  CoreLocation ですれ違い地点を記録する。
//
//  相手の識別は2段構え（設計書v5 4章）:
//   1. 前面の相手 … アドバタイズの LocalName（UUIDを22文字Base64URLに詰めたもの）から復元
//   2. 裏・画面ロック中の相手 … iOS が LocalName を落とすため、接続して GATT 特性（UUID文字列）を読む
//  サービスUUID・特性UUID・値の形式はフロント班のアプリ（BLEEngine.swift）と同じなので相互にすれ違える。
//
//  マッチしない場所（ExclusionZone）の範囲内にいる間は、発信も受信も止める。
//
//  ※ 検知ロジックは参考プロジェクト SurechigaiApp/BLEManager.swift をベースに、
//    SwiftData 依存を外してメモリ保持(@Published)に置き換えた実装。
//    （シミュレータでは BLE ハードウェアが無いため検出は発生しない。
//     その場合は開発者画面の「テストデータを注入」で動作確認できる）
//

import Foundation
import CoreBluetooth
import CoreLocation
import Combine

/// 検出の出所（実機の本物のBLE検出か、デモ用の注入か）
enum DetectionSource: String {
    case ble  = "実機"
    case mock = "テスト"
}

/// 相手のアカウントUUIDをどうやって得たか
enum IdentitySource: String {
    case localName = "LocalName"
    case gatt      = "GATT"
    case cache     = "キャッシュ"   // 少し前に同じ端末から GATT/LocalName で得た値
    case none      = "復元不可"
}

/// アカウントUUIDをBLEのアドバタイズに載せるための詰め替え。
///
/// BLEのアドバタイズは31バイトしかなく、128bitのサービスUUIDだけで18バイト使う。
/// UUIDの文字列表現は36文字あるため、そのままLocalNameに載せると途中で切れて復元できない。
/// UUIDの実体は16バイトなので、Base64URL(22文字)に詰めれば収まる。
enum BLEIdentity {
    static func encode(_ uuid: UUID) -> String {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> UUID? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), data.count == 16 else { return nil }
        return UUID(uuid: data.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
    }
}

/// すれ違いで検出した1件の記録（開発者画面・ローカル表示用）
struct DetectedPeer: Identifiable, Hashable {
    let id: UUID
    let peripheralID: String      // 相手の端末ID（CoreBluetoothの識別子）
    let rssi: Int
    let timestamp: Date
    let latitude: Double?
    let longitude: Double?
    let advertisedName: String?   // 相手がアドバタイズに載せていた識別名（あれば）
    let source: DetectionSource
    /// GATT やキャッシュで得た相手のアカウントUUID（小文字）。LocalName から得られる場合は nil
    let resolvedUUID: String?
    let identitySource: IdentitySource

    init(
        peripheralID: String,
        rssi: Int,
        timestamp: Date = Date(),
        latitude: Double? = nil,
        longitude: Double? = nil,
        advertisedName: String? = nil,
        source: DetectionSource = .ble,
        resolvedUUID: String? = nil,
        identitySource: IdentitySource? = nil
    ) {
        self.id = UUID()
        self.peripheralID = peripheralID
        self.rssi = rssi
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.advertisedName = advertisedName
        self.source = source
        self.resolvedUUID = resolvedUUID?.lowercased()
        if let identitySource {
            self.identitySource = identitySource
        } else {
            self.identitySource = advertisedName.flatMap { BLEIdentity.decode($0) } != nil ? .localName : .none
        }
    }

    /// 相手のアカウントUUID。アドバタイズから復元できたときだけ得られる。
    /// サーバーへ送る peer_uuid はこの値（peripheralID は端末ごとのランダム値なので使えない）。
    /// サーバーのUUIDは小文字のため、Swiftの大文字表現から揃えておく。
    var peerAccountUUID: String? {
        resolvedUUID ?? advertisedName.flatMap { BLEIdentity.decode($0) }?.uuidString.lowercased()
    }

    var proximityLabel: String {
        if rssi >= -60 { return "至近" }
        else if rssi >= -75 { return "近い" }
        else if rssi >= -90 { return "やや遠い" }
        else { return "遠い" }
    }
}

@MainActor
final class BLEManager: NSObject, ObservableObject {

    // MARK: 定数（参考実装と同じサービスUUID）
    static let serviceUUID = CBUUID(string: "12345678-1234-1234-1234-123456789ABC")
    /// アカウントUUID（小文字の36文字文字列）を読み取り専用で公開する GATT 特性
    static let idCharacteristicUUID = CBUUID(string: "12345678-1234-1234-1234-123456789ABD")
    private let cooldownSeconds: TimeInterval = 5

    /// 同じ端末へ GATT 接続を試す最短間隔（接続しっぱなし・電池消費を避ける）
    private let gattRetryInterval: TimeInterval = 20
    /// 接続〜読み取りがこの時間で終わらなければ諦める（connect はタイムアウトしないため）
    private let gattTimeout: TimeInterval = 10
    /// 端末ID→アカウントUUID の対応を覚えておく時間。端末IDは相手側で時々変わるので長くしすぎない
    private let resolvedTTL: TimeInterval = 3600

    // MARK: CoreBluetooth
    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!

    // MARK: 位置情報
    private let locationManager = CLLocationManager()
    private(set) var lastLocation: CLLocation?

    // MARK: 公開状態（UI購読用）
    @Published var recentLogs: [DetectedPeer] = []
    @Published var isScanning = false
    @Published var isAdvertising = false
    @Published var centralState: CBManagerState = .unknown
    @Published var peripheralState: CBManagerState = .unknown
    @Published var totalCount: Int = 0

    /// GATT 読み取りの成功・失敗回数（開発者画面での確認用）
    @Published private(set) var gattSuccessCount = 0
    @Published private(set) var gattFailureCount = 0
    @Published private(set) var lastGATTError: String?

    /// いま入っているマッチしない場所。nil でなければ発信・受信を止めている
    @Published private(set) var activeZone: ExclusionZone?
    /// 位置情報の許可状態（「常に許可」でないと裏にいる間の判定が遅れる）
    @Published private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined

    /// マッチしない場所の一覧（ZoneStore から渡される）
    var zones: [ExclusionZone] = [] {
        didSet {
            reevaluateZone()
            syncZoneMonitor()
            if zones.contains(where: \.isEnabled) { requestAlwaysLocationIfNeeded() }
        }
    }

    /// マッチ受付の On/Off。オフの間は発信も受信も止める（相手に拾われず、自分も拾わない）。
    /// マッチしない場所にいる間も同様に止める（shouldRun 参照）。
    /// ログイン状態が確定するまでは動かさないため既定はオフ。
    @Published var matchEnabled: Bool = false { didSet { applyScan(); applyAdvertise() } }

    /// 受信(スキャン)を行うかどうかの希望状態。実際に動いているかは isScanning を参照。
    @Published var scanEnabled: Bool = true { didSet { applyScan() } }
    /// 発信(アドバタイズ)を行うかどうかの希望状態。実際に動いているかは isAdvertising を参照。
    @Published var advertiseEnabled: Bool = true { didSet { applyAdvertise() } }

    /// アドバタイズに載せるログインユーザーのアカウントUUID。受信側にも伝わる。
    var myAccountUUID: String? { didSet { if advertiseEnabled { applyAdvertise() } } }

    /// すれ違いを検知したときに呼ばれる。サーバー送信の配線に使う。
    var onDetect: ((DetectedPeer) -> Void)?

    /// この端末でBLEが使えないか（シミュレータや非対応端末では true）
    var isBLEUnsupported: Bool { centralState == .unsupported || peripheralState == .unsupported }

    /// 自分の端末ID（このアプリ起動セッションでの識別子。表示用）
    let myDeviceID: String = UUID().uuidString

    // MARK: 内部管理
    private var lastSeenAt: [String: Date] = [:]

    // GATT フォールバック
    private var resolvedIDs: [UUID: (id: String, at: Date)] = [:]
    private var connecting: [UUID: (peripheral: CBPeripheral, rssi: Int)] = [:]
    private var lastConnectAttempt: [UUID: Date] = [:]
    /// GATT サービスに載せているUUID（変わったら作り直す）
    private var publishedServiceID: String?

    // マッチしない場所（CLMonitor は裏にいても出入りを通知してくれる）
    private var zoneMonitor: CLMonitor?
    private var zoneEventsTask: Task<Void, Never>?
    private var monitorInsideIDs: Set<String> = []
    private var askedAlwaysLocation = false

    override init() {
        super.init()
        // queue: nil = メインキュー。デリゲートは MainActor.assumeIsolated で同期的に処理する。
        // 復元ID: 裏で iOS に終了されても、BLEイベントでアプリを起こしてスキャン/発信を続けてもらう。
        centralManager = CBCentralManager(
            delegate: self, queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "surechigai.central"]
        )
        peripheralManager = CBPeripheralManager(
            delegate: self, queue: nil,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "surechigai.peripheral"]
        )
        setupLocation()
    }

    /// 発信・受信してよい状態か（マッチON かつ マッチしない場所の外）
    private var shouldRun: Bool { matchEnabled && activeZone == nil }

    // MARK: 公開メソッド

    /// 希望状態(matchEnabled/scanEnabled)とBLEの電源状態に応じて、スキャンを開始/停止する。
    private func applyScan() {
        guard let cm = centralManager else { return }
        if shouldRun, scanEnabled, cm.state == .poweredOn {
            cm.scanForPeripherals(
                withServices: [Self.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
            isScanning = true
        } else {
            cm.stopScan()
            isScanning = false
            cancelAllGATT()
        }
    }

    /// 希望状態(matchEnabled/advertiseEnabled)とBLEの電源状態に応じて、発信を開始/停止する。
    /// myAccountUUID があれば Base64URL に詰めてアドバタイズに載せる（受信側が相手UUIDとして復元する）。
    /// 同時に GATT サービスにもUUIDを載せ、LocalName が落ちる裏の状態でも接続して読めるようにする。
    private func applyAdvertise() {
        guard let pm = peripheralManager else { return }
        if shouldRun, advertiseEnabled, pm.state == .poweredOn {
            applyGATTService(pm)
            var data: [String: Any] = [
                CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]
            ]
            if let uuid = myAccountUUID.flatMap({ UUID(uuidString: $0) }) {
                data[CBAdvertisementDataLocalNameKey] = BLEIdentity.encode(uuid)
            }
            if pm.isAdvertising { pm.stopAdvertising() }
            pm.startAdvertising(data)
        } else {
            pm.stopAdvertising()
            isAdvertising = false
            // 止めている間は GATT からも読めないようにする
            if pm.state == .poweredOn, publishedServiceID != nil {
                pm.removeAllServices()
                publishedServiceID = nil
            }
        }
    }

    /// GATT サービス（アカウントUUIDの読み取り専用特性）を公開する。UUIDが変わったら作り直す。
    private func applyGATTService(_ pm: CBPeripheralManager) {
        let id = myAccountUUID?.lowercased()
        guard id != publishedServiceID else { return }
        pm.removeAllServices()
        publishedServiceID = nil
        guard let id, UUID(uuidString: id) != nil else { return }
        // value を指定した特性は iOS がキャッシュして応答するので、読み取り要求の処理は不要
        let characteristic = CBMutableCharacteristic(
            type: Self.idCharacteristicUUID,
            properties: [.read],
            value: Data(id.utf8),
            permissions: [.readable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        pm.add(service)
        publishedServiceID = id
    }

    func clearAllLogs() {
        recentLogs.removeAll()
        lastSeenAt.removeAll()
        resolvedIDs.removeAll()
        lastConnectAttempt.removeAll()
        totalCount = 0
        gattSuccessCount = 0
        gattFailureCount = 0
        lastGATTError = nil
    }

    /// シミュレータでも動作確認できるよう、擬似的に1件の検出を注入する（デモ用）。
    /// 実際のアドバタイズと同じ形式で載せるため、送信経路もそのまま確認できる。
    /// （存在しないUUIDなので、モックOFFで注入するとサーバーは404を返す）
    func injectMockDetection() {
        recordEncounter(
            peripheralID: UUID().uuidString,
            rssi: Int.random(in: (-95)...(-45)),
            advertisedName: BLEIdentity.encode(UUID()),
            source: .mock,
            bypassCooldown: true
        )
    }

    /// 指定したアカウントUUIDを BLE で検知したことにする（シミュレータ確認用）。
    /// 実機の検知と同じ経路（マッチしない場所の判定 → サーバー送信 → 失敗時の再送キュー）を通る。
    /// 発信・受信が止まっている状態（マッチOFF・マッチしない場所の中）では、実機と同じく何も起きない。
    /// - Returns: 検知として扱ったか（止まっていて無視したら false）
    @discardableResult
    func injectDetection(peerUUID: String, rssi: Int = -55) -> Bool {
        guard shouldRun else { return false }
        recordEncounter(
            peripheralID: UUID().uuidString,
            rssi: rssi,
            source: .mock,
            resolvedUUID: peerUUID.trimmingCharacters(in: .whitespacesAndNewlines),
            identitySource: .localName,
            bypassCooldown: true
        )
        return true
    }

    // MARK: 内部ヘルパー

    private func setupLocation() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    /// マッチしない場所を登録したら「常に許可」を求める。
    /// 「使用中のみ」だと、裏にいる間に範囲へ入っても気づけず発信を続けてしまうため。
    private func requestAlwaysLocationIfNeeded() {
        guard !askedAlwaysLocation, locationManager.authorizationStatus == .authorizedWhenInUse else { return }
        askedAlwaysLocation = true
        locationManager.requestAlwaysAuthorization()
    }

    private func recordEncounter(
        peripheralID: String,
        rssi: Int,
        advertisedName: String? = nil,
        source: DetectionSource = .ble,
        resolvedUUID: String? = nil,
        identitySource: IdentitySource? = nil,
        bypassCooldown: Bool = false
    ) {
        let now = Date()
        if !bypassCooldown,
           let last = lastSeenAt[peripheralID],
           now.timeIntervalSince(last) < cooldownSeconds {
            return
        }
        lastSeenAt[peripheralID] = now

        let log = DetectedPeer(
            peripheralID: peripheralID,
            rssi: rssi,
            timestamp: now,
            latitude: lastLocation?.coordinate.latitude,
            longitude: lastLocation?.coordinate.longitude,
            advertisedName: advertisedName,
            source: source,
            resolvedUUID: resolvedUUID,
            identitySource: identitySource
        )

        recentLogs.insert(log, at: 0)
        if recentLogs.count > 50 { recentLogs.removeLast() }
        totalCount += 1

        print("[BLE] 検出(\(source.rawValue)/\(log.identitySource.rawValue)): \(peripheralID.prefix(8))… RSSI=\(rssi) 相手UUID=\(log.peerAccountUUID ?? "復元不可")")
        onDetect?(log)
    }

    // MARK: 受信 → 相手の識別

    private func handleDiscovery(_ peripheral: CBPeripheral, rssi: Int, localName: String?) {
        guard shouldRun else { return }
        let pid = peripheral.identifier
        let now = Date()

        // 1. 前面の相手: LocalName から復元できる
        if let localName, let uuid = BLEIdentity.decode(localName) {
            resolvedIDs[pid] = (uuid.uuidString.lowercased(), now)
            recordEncounter(peripheralID: pid.uuidString, rssi: rssi, advertisedName: localName, source: .ble)
            return
        }
        // 2. 少し前に識別済みの端末なら、接続せずに覚えている値を使う
        if let cached = resolvedIDs[pid], now.timeIntervalSince(cached.at) < resolvedTTL {
            recordEncounter(peripheralID: pid.uuidString, rssi: rssi, source: .ble,
                            resolvedUUID: cached.id, identitySource: .cache)
            return
        }
        // 3. LocalName が無い（相手が裏・画面ロック中）→ 接続して GATT 特性を読む
        startGATTRead(peripheral, rssi: rssi)
    }

    private func startGATTRead(_ peripheral: CBPeripheral, rssi: Int) {
        let pid = peripheral.identifier
        guard connecting[pid] == nil,
              Date().timeIntervalSince(lastConnectAttempt[pid] ?? .distantPast) >= gattRetryInterval else { return }
        lastConnectAttempt[pid] = Date()
        connecting[pid] = (peripheral, rssi)
        peripheral.delegate = self
        centralManager.connect(peripheral)
        print("[BLE] GATT接続開始: \(pid.uuidString.prefix(8))… RSSI=\(rssi)")

        let timeout = gattTimeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.finishGATT(pid, resolved: nil, failure: "タイムアウト")
        }
    }

    /// GATT 読み取りを終える（成功・失敗とも）。接続は必ず切る。
    private func finishGATT(_ pid: UUID, resolved: String?, failure: String?) {
        guard let entry = connecting.removeValue(forKey: pid) else { return }
        centralManager.cancelPeripheralConnection(entry.peripheral)
        if let resolved {
            resolvedIDs[pid] = (resolved, Date())
            gattSuccessCount += 1
            recordEncounter(peripheralID: pid.uuidString, rssi: entry.rssi, source: .ble,
                            resolvedUUID: resolved, identitySource: .gatt, bypassCooldown: true)
        } else {
            gattFailureCount += 1
            lastGATTError = failure
            print("[BLE] GATT失敗: \(pid.uuidString.prefix(8))… 理由=\(failure ?? "-")")
            // 復元できなかったことをログに残す（送信はされない）
            recordEncounter(peripheralID: pid.uuidString, rssi: entry.rssi, source: .ble,
                            identitySource: IdentitySource.none, bypassCooldown: true)
        }
    }

    private func cancelAllGATT() {
        for (_, entry) in connecting {
            centralManager?.cancelPeripheralConnection(entry.peripheral)
        }
        connecting.removeAll()
    }

    // MARK: マッチしない場所

    /// 現在地・CLMonitor の状態からいま入っているゾーンを決め、変わったら発信/受信を切り替える。
    /// どちらか一方でも「中」と判定したら止める（プライバシーのため止める側に倒す）。
    private func reevaluateZone() {
        let byLocation = lastLocation.flatMap { loc in zones.first { $0.contains(loc) } }
        let byMonitor = zones.first { $0.isEnabled && monitorInsideIDs.contains($0.id.uuidString) }
        let zone = byLocation ?? byMonitor
        guard zone != activeZone else { return }
        activeZone = zone
        print("[ZONE] \(zone.map { "「\($0.name)」に入ったため発信・受信を停止" } ?? "マッチしない場所の外に出たため再開")")
        applyScan()
        applyAdvertise()
    }

    /// 有効なゾーンを CLMonitor に登録する。アプリが裏にいても出入りでイベントが届く。
    private func syncZoneMonitor() {
        let targets = zones.filter(\.isEnabled)
        Task { @MainActor in
            if zoneMonitor == nil {
                zoneMonitor = await CLMonitor("SurechigaiExclusionZones")
                startZoneEvents()
            }
            guard let monitor = zoneMonitor else { return }
            let wanted = Set(targets.map { $0.id.uuidString })
            for id in await monitor.identifiers where !wanted.contains(id) {
                await monitor.remove(id)
                monitorInsideIDs.remove(id)
            }
            for zone in targets {
                // 同じIDで add すると条件（中心・半径）が置き換わる
                await monitor.add(
                    CLMonitor.CircularGeographicCondition(center: zone.coordinate, radius: zone.radius),
                    identifier: zone.id.uuidString,
                    assuming: .unsatisfied
                )
            }
            reevaluateZone()
        }
    }

    private func startZoneEvents() {
        guard let monitor = zoneMonitor else { return }
        zoneEventsTask?.cancel()
        zoneEventsTask = Task { @MainActor [weak self] in
            do {
                for try await event in await monitor.events {
                    guard let self else { return }
                    if event.state == .satisfied {
                        self.monitorInsideIDs.insert(event.identifier)
                    } else {
                        self.monitorInsideIDs.remove(event.identifier)
                    }
                    self.reevaluateZone()
                }
            } catch {
                print("[ZONE] CLMonitor エラー: \(error)")
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            self.centralState = state
            self.applyScan()
        }
    }

    /// 復元ID を指定しているため必須。状態は applyScan で作り直すので中身は使わない。
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        print("[BLE] Central の状態を復元")
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssiValue = RSSI.intValue
        guard rssiValue < 0 else { return }
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        // queue: nil で生成しているのでメインスレッドで呼ばれる
        MainActor.assumeIsolated {
            self.handleDiscovery(peripheral, rssi: rssiValue, localName: localName)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            self.finishGATT(peripheral.identifier, resolved: nil, failure: "接続失敗: \(error?.localizedDescription ?? "-")")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // 読み取り完了後の切断なら finishGATT 済みで何もしない
        MainActor.assumeIsolated {
            self.finishGATT(peripheral.identifier, resolved: nil, failure: "読み取り前に切断")
        }
    }
}

// MARK: - CBPeripheralDelegate（GATT 読み取り）
extension BLEManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                self.finishGATT(peripheral.identifier, resolved: nil, failure: "サービスなし")
                return
            }
            peripheral.discoverCharacteristics([Self.idCharacteristicUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard let ch = service.characteristics?.first(where: { $0.uuid == Self.idCharacteristicUUID }) else {
                self.finishGATT(peripheral.identifier, resolved: nil, failure: "特性なし")
                return
            }
            peripheral.readValue(for: ch)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil,
                  let data = characteristic.value,
                  let text = String(data: data, encoding: .utf8)?.lowercased(),
                  UUID(uuidString: text) != nil else {
                self.finishGATT(peripheral.identifier, resolved: nil,
                                failure: "読み取り失敗: \(error?.localizedDescription ?? "値が不正")")
                return
            }
            self.finishGATT(peripheral.identifier, resolved: text, failure: nil)
        }
    }
}

// MARK: - CBPeripheralManagerDelegate
extension BLEManager: CBPeripheralManagerDelegate {

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let state = peripheral.state
        Task { @MainActor in
            self.peripheralState = state
            self.applyAdvertise()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // 復元されたサービスは applyGATTService で作り直す（publishedServiceID が nil なので必ず再登録される）
        print("[BLE] Peripheral の状態を復元")
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            print("[BLE] アドバタイズエラー: \(error)")
            return
        }
        Task { @MainActor in self.isAdvertising = true }
    }
}

// MARK: - CLLocationManagerDelegate
extension BLEManager: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in
            self.lastLocation = last
            self.reevaluateZone()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
        if status == .authorizedAlways {
            // 裏にいる間も大きく移動したら位置を更新してもらう（ゾーン判定用。CLMonitor の補助）
            manager.startMonitoringSignificantLocationChanges()
        }
        Task { @MainActor in
            self.locationAuthorization = status
            if status == .authorizedWhenInUse, self.zones.contains(where: \.isEnabled) {
                self.requestAlwaysLocationIfNeeded()
            }
        }
    }
}
