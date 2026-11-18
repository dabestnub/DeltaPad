import Foundation
import CoreBluetooth

protocol PacketLink: AnyObject {
    var onPacket: ((Packet) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var onWaiting: ((String) -> Void)? { get set }
    var closeReason: String { get set }
    func start(ready: (() -> Void)?)
    func send(_ packet: Packet)
    func close(reason: String?)
    func sendThenClose(_ packet: Packet, reason: String)
}
extension PacketLink {
    func close() { close(reason: nil) }
    func start() { start(ready: nil) }
}
extension Wire: PacketLink {}

// Both BLE directions use bounded newline framing, independent of negotiated MTU.
class BluetoothLink: NSObject, PacketLink {
    static let inputID = CBUUID(string: "E227F482-BE82-4CF4-993C-E6F1BE29D102")
    static let outputID = CBUUID(string: "E227F482-BE82-4CF4-993C-E6F1BE29D103")
    var onPacket: ((Packet) -> Void)?
    var onClose: (() -> Void)?
    var onWaiting: ((String) -> Void)?
    var closeReason = "Bluetooth disconnected"
    var closed = false
    var buffer = Data()
    var outgoing = Data()
    func start(ready: (() -> Void)?) { ready?() }
    func send(_ packet: Packet) {
        guard !closed, var data = try? JSONEncoder().encode(packet) else { return }
        data.append(10)
        guard outgoing.count + data.count <= 16384 else { close(reason: "Bluetooth is too slow. Reconnect and try again."); return }
        outgoing.append(data); flush()
    }
    func flush() {}
    func receive(_ data: Data) {
        guard !closed else { return }
        buffer.append(data)
        guard buffer.count <= 16384 else { close(reason: "Invalid Bluetooth data"); return }
        while let index = buffer.firstIndex(of: 10) {
            guard let packet = try? JSONDecoder().decode(Packet.self, from: buffer[..<index]) else { close(reason: "Invalid Bluetooth data"); return }
            buffer.removeSubrange(...index)
            if packet.kind == "disconnect" { close(reason: "Mac disconnected. Scan its QR code again."); return }
            onPacket?(packet)
            if closed { return }
        }
    }
    func close(reason: String?) {
        guard !closed else { return }
        closed = true
        if let reason { closeReason = reason }
        buffer.removeAll(); outgoing.removeAll(); onClose?()
    }
    func sendThenClose(_ packet: Packet, reason: String) {
        send(packet)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.close(reason: reason) }
    }
}

#if os(iOS)
final class BluetoothPhoneLink: BluetoothLink, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var input: CBCharacteristic?
    private var ready: (() -> Void)?
    private let serviceID: CBUUID
    private var writing = false
    init(service: String) { serviceID = CBUUID(string: service); super.init() }
    override func start(ready: (() -> Void)?) {
        self.ready = ready
        manager = CBCentralManager(delegate: self, queue: .main)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !closed else { return }
        switch central.state {
        case .poweredOn: central.scanForPeripherals(withServices: [serviceID])
        case .poweredOff: close(reason: "Turn on Bluetooth on your iPhone, then scan again.")
        case .unauthorized: close(reason: "Allow Bluetooth access for DeltaPad or LiveContainer in Settings → Privacy & Security → Bluetooth.")
        case .unsupported: close(reason: "Bluetooth is unavailable on this device.")
        case .resetting: close(reason: "Bluetooth restarted. Scan again.")
        default: break
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !closed, self.peripheral == nil else { return }
        self.peripheral = peripheral; peripheral.delegate = self
        central.stopScan(); central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !closed else { central.cancelPeripheralConnection(peripheral); return }
        peripheral.discoverServices([serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { close(reason: error?.localizedDescription ?? "Could not connect over Bluetooth.") }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { close(reason: "Bluetooth disconnected. Move closer to the Mac and scan again.") }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !closed else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else { close(reason: "Mac Bluetooth service unavailable."); return }
        peripheral.discoverCharacteristics([Self.inputID, Self.outputID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !closed else { return }
        guard error == nil, let input = service.characteristics?.first(where: { $0.uuid == Self.inputID }),
              let output = service.characteristics?.first(where: { $0.uuid == Self.outputID }) else { close(reason: "Update the Mac companion for Bluetooth."); return }
        self.input = input; peripheral.setNotifyValue(true, for: output)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !closed else { return }
        guard error == nil, characteristic.isNotifying else { close(reason: "Could not start Bluetooth notifications."); return }
        let callback = ready; ready = nil; callback?()
    }
    override func flush() {
        guard !closed, !writing, let peripheral, let input, !outgoing.isEmpty else { return }
        let count = min(outgoing.count, peripheral.maximumWriteValueLength(for: .withResponse))
        guard count > 0 else { return }
        let chunk = Data(outgoing.prefix(count)); outgoing.removeFirst(count); writing = true
        peripheral.writeValue(chunk, for: input, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writing = false
        if let error { close(reason: error.localizedDescription) } else { flush() }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { close(reason: error.localizedDescription); return }
        if let data = characteristic.value { receive(data) }
    }
    override func close(reason: String?) {
        guard !closed else { return }
        manager?.stopScan()
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        ready = nil; super.close(reason: reason)
    }
}
#elseif os(macOS)
final class BluetoothMacLink: BluetoothLink {
    let central: CBCentral
    weak var server: BluetoothServer?
    init(central: CBCentral, server: BluetoothServer) { self.central = central; self.server = server; super.init() }
    override func flush() { server?.flush(self) }
    override func close(reason: String?) {
        guard !closed else { return }
        // Best effort; the phone also has a heartbeat watchdog.
        if let server { server.notifyDisconnect(self) }
        super.close(reason: reason)
        server?.remove(self)
    }
}
final class BluetoothServer: NSObject, CBPeripheralManagerDelegate {
    let serviceID: CBUUID
    var onStatus: ((String) -> Void)?
    var onConnection: ((BluetoothMacLink) -> Void)?
    private var manager: CBPeripheralManager!
    private var output: CBMutableCharacteristic?
    private var link: BluetoothMacLink?
    init(service: String) { serviceID = CBUUID(string: service); super.init() }
    func start() { manager = CBPeripheralManager(delegate: self, queue: .main) }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        link?.close(reason: "Bluetooth state changed")
        switch peripheral.state {
        case .poweredOn:
            peripheral.removeAllServices()
            let input = CBMutableCharacteristic(type: BluetoothLink.inputID, properties: [.write], value: nil, permissions: [.writeable])
            let output = CBMutableCharacteristic(type: BluetoothLink.outputID, properties: [.notify], value: nil, permissions: [])
            self.output = output
            let service = CBMutableService(type: serviceID, primary: true); service.characteristics = [input, output]
            peripheral.add(service)
        case .poweredOff: onStatus?("Turn on Bluetooth on your Mac.")
        case .unauthorized: onStatus?("Allow DeltaPadMac in System Settings → Privacy & Security → Bluetooth.")
        case .unsupported: onStatus?("Bluetooth is unavailable on this Mac.")
        default: onStatus?("Bluetooth is starting…")
        }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { onStatus?("Bluetooth: \(error.localizedDescription)"); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID], CBAdvertisementDataLocalNameKey: "DeltaPad Mac"])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        onStatus?(error.map { "Bluetooth: \($0.localizedDescription)" } ?? "Bluetooth ready • no hotspot needed")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == BluetoothLink.outputID, link == nil else { return }
        let next = BluetoothMacLink(central: central, server: self); link = next; onConnection?(next)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if link?.central.identifier == central.identifier { link?.close(reason: "Phone disconnected") }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard let link, !link.closed, requests.allSatisfy({ $0.central.identifier == link.central.identifier && $0.characteristic.uuid == BluetoothLink.inputID && $0.offset == 0 && $0.value != nil }) else {
            peripheral.respond(to: first, withResult: .unlikelyError); return
        }
        peripheral.respond(to: first, withResult: .success)
        for request in requests { if let data = request.value { link.receive(data) } }
    }
    func flush(_ link: BluetoothMacLink) {
        guard !link.closed, let output else { return }
        while !link.outgoing.isEmpty {
            let count = min(link.outgoing.count, link.central.maximumUpdateValueLength)
            guard count > 0 else { return }
            let chunk = Data(link.outgoing.prefix(count))
            guard manager.updateValue(chunk, for: output, onSubscribedCentrals: [link.central]) else { return }
            link.outgoing.removeFirst(count)
        }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { if let link { flush(link) } }
    func notifyDisconnect(_ link: BluetoothMacLink) {
        guard manager.state == .poweredOn, let output else { return }
        _ = manager.updateValue(Data("{\"kind\":\"disconnect\"}\n".utf8), for: output, onSubscribedCentrals: [link.central])
    }
    func remove(_ value: BluetoothMacLink) { if link === value { link = nil } }
}
#endif
