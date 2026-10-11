// GATT 検証用の Mac 側ツール
//  peripheral <uuid> : LocalName なしでサービスUUIDだけ発信し、特性にUUIDを載せる（=裏にいるiPhoneのふり）
//  central           : サービスUUIDでスキャンし、LocalName なしの相手に接続して特性を読む
import Foundation
import CoreBluetooth

let serviceUUID = CBUUID(string: "12345678-1234-1234-1234-123456789ABC")
let charUUID = CBUUID(string: "12345678-1234-1234-1234-123456789ABD")
setvbuf(stdout, nil, _IOLBF, 0)

final class Peripheral: NSObject, CBPeripheralManagerDelegate {
    var pm: CBPeripheralManager!
    let id: String
    init(id: String) { self.id = id; super.init(); pm = CBPeripheralManager(delegate: self, queue: nil) }
    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        print("peripheral state=\(p.state.rawValue)")
        guard p.state == .poweredOn else { return }
        let ch = CBMutableCharacteristic(type: charUUID, properties: [.read], value: Data(id.utf8), permissions: [.readable])
        let s = CBMutableService(type: serviceUUID, primary: true); s.characteristics = [ch]
        p.add(s)
    }
    func peripheralManager(_ p: CBPeripheralManager, didAdd s: CBService, error: Error?) {
        print("service added err=\(String(describing: error))")
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])  // LocalName なし
    }
    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) { print("advertising err=\(String(describing: error))") }
    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead r: CBATTRequest) { print("read request") }
    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo c: CBCharacteristic) {}
}

final class Central: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var cm: CBCentralManager!
    var peers: [UUID: CBPeripheral] = [:]
    var done: Set<UUID> = []
    override init() { super.init(); cm = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("central state=\(c.state.rawValue)")
        if c.state == .poweredOn { c.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
        guard peers[p.identifier] == nil, !done.contains(p.identifier) else { return }
        let name = a[CBAdvertisementDataLocalNameKey] as? String
        print("discovered \(p.identifier.uuidString.prefix(8)) rssi=\(rssi) localName=\(name ?? "なし")")
        peers[p.identifier] = p; p.delegate = self; c.connect(p)
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { print("connected"); p.discoverServices([serviceUUID]) }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { print("connect failed \(String(describing: error))"); peers[p.identifier] = nil }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == serviceUUID }) else { print("no service"); return }
        p.discoverCharacteristics([charUUID], for: s)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let ch = s.characteristics?.first(where: { $0.uuid == charUUID }) else { print("no characteristic"); return }
        p.readValue(for: ch)
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        print("GATT READ: \(ch.value.flatMap { String(data: $0, encoding: .utf8) } ?? "nil") err=\(String(describing: error))")
        done.insert(p.identifier); peers[p.identifier] = nil
        cm.cancelPeripheralConnection(p)
    }
}

let args = CommandLine.arguments
var keep: AnyObject?
if args.count >= 3, args[1] == "peripheral" { keep = Peripheral(id: args[2]) }
else if args.count >= 2, args[1] == "central" { keep = Central() }
else { print("usage: bletool peripheral <uuid> | central"); exit(1) }
let seconds = Double(ProcessInfo.processInfo.environment["DURATION"] ?? "60") ?? 60
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
_ = keep
