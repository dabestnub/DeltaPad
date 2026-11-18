import SwiftUI
import AppKit
import ApplicationServices
import Network
import Darwin
import CoreImage.CIFilterBuiltins

final class Bridge: ObservableObject {
    @Published var status = "Starting…"
    @Published var addresses = ""
    @Published var activeProfile = ControllerProfile.snesDs
    @Published var inputStatus = ""
    @Published var selectedAddress = ""
    private var clickRelease: DispatchWorkItem?
    @Published var code = String(Int.random(in: 100000...999999))
    private var listener: NWListener?
    private var peer: (any PacketLink)?
    @Published var bluetoothStatus = "Bluetooth is starting…"
    private var bluetoothServer: BluetoothServer?
    private let bluetoothID: String = {
        if let value = UserDefaults.standard.string(forKey: "bluetoothServiceID"), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString; UserDefaults.standard.set(value, forKey: "bluetoothServiceID"); return value
    }()
    private var paired = false
    private var held = Set<String>()
    private var mouseDown = false
    private var lastSeen = Date()
    private var timer: Timer?
    private var focusObserver: NSObjectProtocol?
    // Physical US keyboard key codes; configure these in Delta's DS mapping.
    let keys: [String: CGKeyCode] = ["up":126,"down":125,"left":123,"right":124,
        "A":7,"B":6,"X":1,"Y":0,"L":12,"R":13,"start":36,"select":48,"menu":53,
        "Z":14, "stickUp":34, "stickDown":40, "stickLeft":38, "stickRight":37,
        "cUp":17, "cDown":5, "cLeft":3, "cRight":4]
    var deltaFocused: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.rileytestut.Delta"
    }
    init() {
        refreshAddresses()
        let server = BluetoothServer(service: bluetoothID)
        bluetoothServer = server
        server.onStatus = { [weak self] in self?.bluetoothStatus = $0 }
        server.onConnection = { [weak self] in self?.acceptLink($0) }
        server.start()
        do {
            let listener = try NWListener(using: .tcp, on: 49832)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.status = "Ready to pair"
                case .failed(let error), .waiting(let error):
                    self?.status = "Connection unavailable: \(error.localizedDescription). Check Local Network permission and close any other DeltaPadMac copy."
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: .main)
        } catch { status = error.localizedDescription }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let inputStatus = !AXIsProcessTrusted() ? "Enable Accessibility for this copy of DeltaPadMac." : !self.deltaFocused ? "Click Delta's game window to enable input." : "Input ready"
            if self.inputStatus != inputStatus { self.inputStatus = inputStatus }
            if !self.deltaFocused { self.releaseAll() }
            if self.peer != nil && Date().timeIntervalSince(self.lastSeen) > (self.paired ? 3 : 20) {
                self.peer?.close()
            }
        }
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.deltaFocused == false { self?.releaseAll() }
        }
    }
    func refreshAddresses() {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { addresses = "Check System Settings → Wi-Fi → Details"; return }
        defer { freeifaddrs(list) }
        var found: [String] = []
        var current = list
        while let entry = current {
            let item = entry.pointee
            let name = String(cString: item.ifa_name)
            if name.hasPrefix("en"), (item.ifa_flags & UInt32(IFF_UP)) != 0,
               let addr = item.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    found.append(String(cString: host))
                }
            }
            current = item.ifa_next
        }
        if !found.contains(selectedAddress) { selectedAddress = found.first ?? "" }
        addresses = found.isEmpty ? "Connect your Mac to Wi-Fi, then click Refresh" : found.joined(separator: "  /  ")
    }
    var pairingImage: NSImage? {
        guard let text = PairingCode(address: IPv4Address(selectedAddress) != nil ? selectedAddress : "127.0.0.1", code: code, bluetooth: bluetoothID).encoded else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    func accept(_ connection: NWConnection) {
        guard peer == nil else { connection.cancel(); return }
        acceptLink(Wire(connection))
    }
    func acceptLink(_ wire: any PacketLink) {
        guard peer == nil else { wire.sendThenClose(Packet(kind: "disconnect"), reason: "Another phone is connected"); return }
        peer = wire; paired = false; lastSeen = Date(); status = "Phone reached Mac — waiting for pairing"
        wire.onPacket = { [weak self, weak wire] packet in
            guard let self, let wire else { return }
            if !self.paired {
                guard packet.kind == "pair", packet.code == self.code else {
                    self.status = "Pairing rejected — enter the current code"
                    wire.sendThenClose(Packet(kind: "pairRejected"), reason: "Incorrect pairing code")
                    return
                }
                self.paired = true
                self.code = String(Int.random(in: 100000...999999))
                self.status = "Connected • Bring Delta to the front"
                wire.send(Packet(kind: "paired"))
            } else {
                self.handle(packet)
                if packet.kind == "state" { wire.send(Packet(kind: "pong")) }
            }
            self.lastSeen = Date()
        }
        wire.onClose = { [weak self] in
            guard let self else { return }
            self.releaseAll(); self.peer = nil; self.paired = false; self.status = "Disconnected — ready to pair again"
        }
        wire.start()
    }
    func handle(_ packet: Packet) {
        if packet.kind == "profile", let value = packet.profile, let profile = ControllerProfile(rawValue: value) {
            releaseAll(); activeProfile = profile; return
        }
        guard deltaFocused, AXIsProcessTrusted() else { releaseAll(); return }
        if packet.kind == "state" {
            let next = Set(packet.buttons ?? []).intersection(Set(keys.keys))
            for name in held.subtracting(next) { key(name, false) }
            for name in next.subtracting(held) { key(name, true) }
            held = next
        } else if packet.kind == "pointer" {
            guard let dx = packet.dx, let dy = packet.dy, dx.isFinite, dy.isFinite else { return }
            var position = CGEvent(source: nil)?.location ?? .zero
            position.x += max(-100, min(100, dx))
            position.y += max(-100, min(100, dy))
            let bounds = CGDisplayBounds(CGMainDisplayID())
            position.x = max(bounds.minX, min(bounds.maxX - 1, position.x))
            position.y = max(bounds.minY, min(bounds.maxY - 1, position.y))
            CGEvent(mouseEventSource: nil, mouseType: mouseDown ? .leftMouseDragged : .mouseMoved,
                    mouseCursorPosition: position, mouseButton: .left)?.post(tap: .cghidEventTap)
        } else if packet.kind == "click" {
            guard !mouseDown else { return }
            mouse(true)
            let release = DispatchWorkItem { [weak self] in self?.mouse(false) }
            clickRelease = release
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: release)
        } else if packet.kind == "mouse", let down = packet.down, down != mouseDown {
            mouse(down)
        }
    }
    func key(_ name: String, _ down: Bool) {
        guard let key = keys[name] else { return }
        CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)?.post(tap: .cghidEventTap)
    }
    func mouse(_ down: Bool) {
        clickRelease?.cancel(); clickRelease = nil
        mouseDown = down
        CGEvent(mouseEventSource: nil, mouseType: down ? .leftMouseDown : .leftMouseUp,
                mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero,
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    func releaseAll() {
        for name in held { key(name, false) }
        held.removeAll()
        if mouseDown { mouse(false) }
    }
    func disconnect() { peer?.close(); releaseAll() }
    func permission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

@main struct DeltaPadMacApp: App {
    @StateObject private var bridge = Bridge()
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("DeltaPad").font(.largeTitle.bold())
                    Text(bridge.status).foregroundStyle(.secondary)
                    Text(bridge.bluetoothStatus).font(.callout).foregroundStyle(.secondary)
                    Text(bridge.inputStatus).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 20) {
                        if let qr = bridge.pairingImage {
                            Image(nsImage: qr).interpolation(.none).resizable()
                                .frame(width: 190, height: 190).padding(16).background(.white)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Scan to pair").font(.title2.bold())
                            Text("Tap Scan QR Code on your iPhone and point the camera here.")
                            Text("Choose Bluetooth on your phone to connect without a hotspot. Wi-Fi is also available.").foregroundStyle(.secondary)
                            Button("Refresh address") { bridge.refreshAddresses() }
                        }
                    }
                    if bridge.addresses.contains(" / ") {
                        Picker("Network address", selection: $bridge.selectedAddress) {
                            ForEach(bridge.addresses.components(separatedBy: "  /  "), id: \.self) { address in
                                Text(address).tag(address)
                            }
                        }
                    }
                    DisclosureGroup("Manual pairing details") {
                        Text(bridge.selectedAddress.isEmpty ? bridge.addresses : bridge.selectedAddress).textSelection(.enabled)
                        Text(bridge.code).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                    }
                    HStack {
                        Button("Allow controller input") { bridge.permission() }
                        Button("Disconnect") { bridge.disconnect() }
                    }
                    Divider()
                    Text("Delta keyboard mapping").font(.headline)
                    Picker("System", selection: $bridge.activeProfile) {
                        ForEach(ControllerProfile.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Select Keyboard for Player 1 and map these keys for the game's system:")
                    Text(bridge.activeProfile.keyboardMapping).font(.system(.body, design: .monospaced))
                    if bridge.activeProfile == .n64 {
                        Text("The N64 stick uses eight keyboard directions, not variable analog movement.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Keep Delta in front on the main display. Slide on the touchpad to move the cursor; tap to click. Hold briefly, then slide to drag.")
                        .foregroundStyle(.secondary)
                }.padding(24)
            }.frame(width: 570, height: 640)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in bridge.disconnect() }
        }.windowResizability(.contentSize)
    }
}
