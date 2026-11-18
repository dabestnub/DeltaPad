import SwiftUI
import UIKit
import Network
import AVFoundation
import UniformTypeIdentifiers

final class Controller: ObservableObject {
    @Published var status = "Scan the QR code shown in the Mac companion"
    @Published var connected = false
    @Published var connecting = false
    private var wire: (any PacketLink)?
    private var timer: Timer?
    private var timeout: DispatchWorkItem?
    private var held = Set<String>()
    private var reachedMac = false
    private var waitingDetail = ""
    private var activeProfile = ControllerProfile.snesDs
    private var lastReply = Date()
    func connect(address: String, code: String) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4Address(address) != nil else {
            status = "Enter the Mac's numeric address, for example 192.168.1.20"
            return
        }
        guard code.count == 6, code.allSatisfy({ $0.isNumber }) else {
            status = "Enter the six-digit pairing code"; return
        }
        connect(.hostPort(host: NWEndpoint.Host(address), port: 49832), code: code)
    }
    func connect(_ endpoint: NWEndpoint, code: String) {
        connectLink(Wire(NWConnection(to: endpoint, using: .tcp)), code: code, bluetooth: false)
    }
    func connectBluetooth(service: String, code: String) {
        guard UUID(uuidString: service) != nil else { status = "Scan a QR code from the updated Mac companion."; return }
        connectLink(BluetoothPhoneLink(service: service), code: code, bluetooth: true)
    }
    private func connectLink(_ wire: any PacketLink, code: String, bluetooth: Bool) {
        disconnect()
        connecting = true; reachedMac = false; waitingDetail = ""
        status = bluetooth ? "Looking for your Mac over Bluetooth…" : "Contacting Mac…"
        self.wire = wire
        wire.onWaiting = { [weak self] detail in self?.waitingDetail = detail; self?.status = detail }
        wire.onPacket = { [weak self, weak wire] packet in
            guard let self else { return }
            self.lastReply = Date()
            if packet.kind == "pairRejected" { wire?.close(reason: "Incorrect pairing code. Enter the code currently shown on the Mac."); return }
            guard packet.kind == "paired" else { return }
            self.timeout?.cancel(); self.connected = true; self.connecting = false
            self.status = "Connected"; UIApplication.shared.isIdleTimerDisabled = true
            self.wire?.send(Packet(profile: self.activeProfile.rawValue, kind: "profile"))
            self.timer?.invalidate()
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                if bluetooth && Date().timeIntervalSince(self.lastReply) > 5 {
                    self.wire?.close(reason: "Bluetooth connection lost. Move closer and scan again.")
                } else { self.sendState() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        wire.onClose = { [weak self, weak wire] in
            guard let self else { return }
            self.timeout?.cancel(); self.timer?.invalidate(); self.timer = nil
            self.held.removeAll(); self.connected = false; self.connecting = false
            self.wire = nil; self.status = wire?.closeReason ?? "Disconnected"
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let timeout = DispatchWorkItem { [weak self, weak wire] in
            guard let self else { return }
            let message = bluetooth ? "Bluetooth pairing timed out. Keep the Mac companion open, enable Bluetooth on both devices, allow Bluetooth access, and scan its current QR code again." : self.reachedMac
                ? "Reached the Mac, but pairing did not finish. Check its current pairing code."
                : "Cannot reach the Mac. Check its address and LiveContainer Local Network permission. Guest or school Wi-Fi may block devices from connecting."
            wire?.close(reason: message + (self.waitingDetail.isEmpty ? "" : "\n" + self.waitingDetail))
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        wire.start { [weak self, weak wire] in
            self?.reachedMac = true; self?.status = "Mac reached — checking pairing code…"
            wire?.closeReason = "Mac closed the connection. Check its pairing code and disconnect any other controller."
            wire?.send(Packet(kind: "pair", code: code))
        }
    }
    func button(_ name: String, down: Bool) {
        if down { held.insert(name) } else { held.remove(name) }
        sendState()
    }
    func setProfile(_ profile: ControllerProfile) {
        releaseInputs(); activeProfile = profile
        if connected { wire?.send(Packet(profile: profile.rawValue, kind: "profile")) }
    }
    func joystick(_ directions: Set<String>) {
        if activeProfile == .n64 {
            held.subtract(["stickUp", "stickDown", "stickLeft", "stickRight"])
            let names = ["up": "stickUp", "down": "stickDown", "left": "stickLeft", "right": "stickRight"]
            held.formUnion(directions.compactMap { names[$0] })
        } else {
            held.subtract(["up", "down", "left", "right"]); held.formUnion(directions)
        }
        sendState()
    }
    func click() { if connected { wire?.send(Packet(kind: "click")) } }
    func releaseInputs() {
        held.removeAll(); sendState(); stylus(false)
    }
    func sendState() { if connected { wire?.send(Packet(kind: "state", buttons: Array(held))) } }
    func move(_ delta: CGSize) { wire?.send(Packet(kind: "pointer", dx: delta.width * 2, dy: delta.height * 2)) }
    func stylus(_ down: Bool) { wire?.send(Packet(kind: "mouse", down: down)) }
    func disconnect() {
        held.removeAll(); sendState(); stylus(false); wire?.close(reason: "Disconnected")
    }

}

enum TouchFeedback {
    private static var lastTime: TimeInterval = 0
    static func pulse() {
        let enabled = UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTime > 0.045 else { return }
        lastTime = now
        let raw = UserDefaults.standard.object(forKey: "hapticStrength") as? Double ?? 0.65
        let strength = min(1, max(0.05, raw))
        let generator = UIImpactFeedbackGenerator(style: strength < 0.34 ? .light : strength < 0.67 ? .medium : .heavy)
        generator.prepare(); generator.impactOccurred(intensity: strength)
    }
}

// A separate UIKit control per button preserves simultaneous held touches.
final class PressView: UIView {
    var changed: ((Bool) -> Void)?
    var pressed = false
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { set(true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { set(false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { set(false) }
    func set(_ value: Bool) { if pressed != value { pressed = value; alpha = value ? 0.5 : 1; if value { TouchFeedback.pulse() }; changed?(value) } }
    override func didMoveToWindow() { if window == nil { set(false) } }
}
struct HoldButton: UIViewRepresentable {
    let title: String
    let color: UIColor
    var fontSize: CGFloat = 20
    let changed: (Bool) -> Void
    func makeUIView(context: Context) -> PressView {
        let view = PressView(); view.backgroundColor = color; view.layer.cornerRadius = 16
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.18
        view.layer.shadowRadius = 8
        view.layer.shadowOffset = CGSize(width: 0, height: 4)
        view.accessibilityLabel = title; view.isAccessibilityElement = true; view.accessibilityTraits = .button
        let label = UILabel(); label.text = title; label.textColor = .white
        label.font = .boldSystemFont(ofSize: fontSize); label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor), label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        view.changed = changed; return view
    }
    func updateUIView(_ uiView: PressView, context: Context) {
        uiView.changed = changed; uiView.backgroundColor = color
        if let label = uiView.subviews.first as? UILabel { label.font = .boldSystemFont(ofSize: fontSize); label.text = title }
    }
}
final class LayoutStore: ObservableObject {
    @Published var profile: ControllerProfile
    @Published var controls: [ControlLayout]
    init() {
        let profile = ControllerProfile(rawValue: UserDefaults.standard.string(forKey: "controllerProfile") ?? "") ?? .snesDs
        self.profile = profile; self.controls = Self.load(profile)
    }
    static func load(_ profile: ControllerProfile) -> [ControlLayout] {
        let key = "controllerLayout.v2." + profile.rawValue
        let data = UserDefaults.standard.data(forKey: key) ?? (profile == .snesDs ? UserDefaults.standard.data(forKey: "controllerLayout.v1") : nil)
        return ControlLayout.restored(data, defaults: profile.defaults)
    }
    func select(_ profile: ControllerProfile) {
        self.profile = profile; controls = Self.load(profile)
        UserDefaults.standard.set(profile.rawValue, forKey: "controllerProfile")
    }
    func save(_ controls: [ControlLayout]) {
        guard let data = try? JSONEncoder().encode(controls) else { return }
        UserDefaults.standard.set(data, forKey: "controllerLayout.v2." + profile.rawValue)
        self.controls = controls
    }
}

struct ConfigDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ControllerConfig.ConfigError.invalid }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct PhoneView: View {
    @StateObject private var controller = Controller()
    @StateObject private var layout = LayoutStore()
    @State private var code = ""
    @AppStorage("macAddress") private var address = ""
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("dsTouchpadEnabled") private var dsTouchpadEnabled = true
    @AppStorage("snapControlsToGrid") private var snap = true
    @AppStorage("controlGridSpacing") private var gridSize = 16.0
    @State private var scanning = false
    @State private var scannedPair: PairingCode?
    @State private var manual = false
    @AppStorage("useBluetooth") private var useBluetooth = true
    @State private var confirmExit = false
    @State private var customizing = false
    @State private var draft = ControlLayout.defaults
    @State private var selected = "A"
    @State private var dragStart: CGPoint?
    @State private var inspector = false
    @State private var inspectorTab = 0
    @State private var inspectorPosition: CGPoint?
    @State private var inspectorDragStart: CGPoint?
    @AppStorage("hapticStrength") private var hapticStrength = 0.65
    @AppStorage("recentControlColors") private var recentColorData = "[]"
    @State private var resetConfirmation = false
    @State private var exportingConfig = false
    @State private var importingConfig = false
    @State private var configDocument = ConfigDocument(data: Data())
    @State private var pendingConfig: ControllerConfig?
    @State private var confirmImport = false
    @State private var configMessage = ""
    @State private var showConfigMessage = false
    @FocusState private var editing: Bool
    @Environment(\.scenePhase) private var phase
    private let mint = Color(red: 0.47, green: 0.96, blue: 0.79)
    private var selectedIndex: Int { draft.firstIndex { $0.id == selected } ?? 0 }
    func tint(_ name: String) -> UIColor {
        if name.hasPrefix("#"), name.count == 7, let rgb = UInt32(name.dropFirst(), radix: 16) {
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        switch name {
        case "mint": return UIColor(red: 0.18, green: 0.62, blue: 0.49, alpha: 1)
        case "violet": return UIColor(red: 0.42, green: 0.37, blue: 0.72, alpha: 1)
        case "gold": return UIColor(red: 0.72, green: 0.55, blue: 0.16, alpha: 1)
        case "coral": return UIColor(red: 0.76, green: 0.32, blue: 0.36, alpha: 1)
        case "blue": return UIColor(red: 0.22, green: 0.45, blue: 0.72, alpha: 1)
        default: return UIColor(red: 0.14, green: 0.18, blue: 0.23, alpha: 1)
        }
    }
    func beginEditing() {
        controller.releaseInputs(); draft = layout.controls; selected = "A"; customizing = true; inspector = true; inspectorPosition = nil
    }
    private func exportConfig() {
        controller.releaseInputs()
        let config = ControllerConfig(selectedProfile: layout.profile,
            layouts: Dictionary(uniqueKeysWithValues: ControllerProfile.allCases.map { ($0.rawValue, LayoutStore.load($0)) }),
            hapticsEnabled: hapticsEnabled, hapticStrength: hapticStrength,
            dsTouchpadEnabled: dsTouchpadEnabled, snapToGrid: snap, gridSpacing: gridSize, recentColors: recentColors)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            configDocument = ConfigDocument(data: try encoder.encode(config)); exportingConfig = true
        } catch { reportConfig(error.localizedDescription) }
    }
    private func reportConfig(_ message: String) { configMessage = message; showConfigMessage = true }
    private func readConfig(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            // Bound the read even when a provider does not report a file size.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_000_001) ?? Data()
            pendingConfig = try ControllerConfig.read(data); confirmImport = true
        } catch { reportConfig(error.localizedDescription) }
    }
    private func applyConfig() {
        guard let config = pendingConfig else { return }
        do {
            let encoded = try config.layouts.mapValues { try JSONEncoder().encode($0) }
            let colors = try JSONEncoder().encode(config.recentColors)
            controller.releaseInputs()
            for (key, data) in encoded { UserDefaults.standard.set(data, forKey: "controllerLayout.v2." + key) }
            hapticsEnabled = config.hapticsEnabled; hapticStrength = config.hapticStrength
            dsTouchpadEnabled = config.dsTouchpadEnabled; snap = config.snapToGrid; gridSize = config.gridSpacing
            recentColorData = String(decoding: colors, as: UTF8.self)
            layout.select(config.selectedProfile); controller.setProfile(config.selectedProfile)
            pendingConfig = nil; reportConfig("Imported all controller layouts and settings.")
        } catch { reportConfig(error.localizedDescription) }
    }
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.035, green: 0.065, blue: 0.095), Color(red: 0.065, green: 0.095, blue: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(spacing: 0) {
                toolbar.padding(.horizontal, 18).frame(height: 46)
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                if customizing || controller.connected {
                    controlCanvas.padding(.horizontal, 12).padding(.top, 6)
                    footer.frame(height: 28).padding(.horizontal, 18)
                } else {
                    pairing
                }
            }
        }.preferredColorScheme(.dark).tint(mint)
        .onAppear { controller.setProfile(layout.profile) }
        .fileExporter(isPresented: $exportingConfig, document: configDocument, contentType: .json, defaultFilename: "DeltaPad-Controllers") { result in
            if case .failure(let error) = result { reportConfig(error.localizedDescription) }
        }
        .fileImporter(isPresented: $importingConfig, allowedContentTypes: [.json], allowsMultipleSelection: false, onCompletion: readConfig)
        .confirmationDialog("Replace your controller configs?", isPresented: $confirmImport, titleVisibility: .visible) {
            Button("Import and replace", role: .destructive) { applyConfig() }
            Button("Cancel", role: .cancel) { pendingConfig = nil }
        } message: { Text("This replaces all saved console layouts, colors, haptics, and grid settings. Export your current configs first if you want to keep a copy.") }
        .alert("Controller configs", isPresented: $showConfigMessage) { Button("OK", role: .cancel) {} } message: { Text(configMessage) }
        .confirmationDialog("Disconnect from your Mac?", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { controller.disconnect() }
            Button("Keep playing", role: .cancel) {}
        }
        .confirmationDialog("Reset your layout?", isPresented: $resetConfirmation, titleVisibility: .visible) {
            Button("Reset all controls", role: .destructive) { draft = layout.profile.defaults }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: confirmExit) { if $0 { controller.releaseInputs() } }
        .sheet(isPresented: $scanning, onDismiss: {
            if let pair = scannedPair {
                scannedPair = nil; address = pair.address; code = pair.code
                if useBluetooth {
                    if let service = pair.bluetooth { controller.connectBluetooth(service: service, code: pair.code) }
                    else { controller.status = "This QR code is Wi-Fi only. Update the Mac companion or choose Wi-Fi." }
                } else { controller.connect(address: pair.address, code: pair.code) }
            }
        }) {
            VStack {
                HStack {
                    Label("Scan your Mac", systemImage: "qrcode.viewfinder").font(.headline)
                    Spacer(); Button("Cancel") { scanning = false }
                }.padding()
                QRScanner { pair in scannedPair = pair; scanning = false }
            }.preferredColorScheme(.dark)
        }
        .onChange(of: phase) { value in
            if value != .active { controller.releaseInputs() }
            if value == .background { controller.disconnect() }
        }
    }
    private var toolbar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill").foregroundStyle(mint)
                Text("DELTA PAD").font(.system(size: 12, weight: .bold, design: .rounded)).tracking(2)
            }
            if !customizing {
                Menu {
                    Picker("System", selection: Binding(get: { layout.profile }, set: { profile in
                        controller.setProfile(profile); layout.select(profile); selected = "A"
                    })) {
                        ForEach(ControllerProfile.allCases) { Text($0.title).tag($0) }
                    }
                    if layout.profile == .snesDs {
                        Toggle("DS touchscreen", isOn: $dsTouchpadEnabled)
                    }
                } label: {
                    HStack(spacing: 4) { Text(layout.profile.title); Image(systemName: "chevron.down").font(.system(size: 8)) }.font(.caption.bold())
                }
            }
            Spacer(minLength: 4)
            if customizing {
                Toggle("Snap to grid", isOn: $snap).toggleStyle(.button).font(.caption)
                Button("Reset") { resetConfirmation = true }.font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { customizing = false; dragStart = nil }.font(.caption)
                Button("Save") { layout.save(draft); customizing = false; dragStart = nil }
                    .font(.caption.bold()).buttonStyle(.borderedProminent).foregroundStyle(.black)
            } else {
                Button { beginEditing() } label: { Label("Customize controls", systemImage: "slider.horizontal.3") }.font(.caption)
                Menu {
                    Button { exportConfig() } label: { Label("Export controller configs…", systemImage: "square.and.arrow.up") }
                    Button { controller.releaseInputs(); importingConfig = true } label: { Label("Import controller configs…", systemImage: "square.and.arrow.down") }
                    Divider()
                    Toggle("Haptic feedback", isOn: $hapticsEnabled)
                    Button("Haptic strength…") { beginEditing(); inspectorTab = 2 }
                    if controller.connected {
                        Button("Disconnect", role: .destructive) { confirmExit = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).padding(.vertical, 8)
                }.accessibilityLabel("Controller settings")
            }
        }
    }
    private var footer: some View {
        HStack {
            if customizing {
                Text("Drag to move · tap to select").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(draft[selectedIndex].title).font(.caption.bold())
                Button { inspector.toggle(); inspectorPosition = nil } label: { Label("Size & style", systemImage: "arrow.up.left.and.arrow.down.right") }.font(.caption)
            } else {
                Circle().fill(mint).frame(width: 5, height: 5)
                Text("CONNECTED").font(.system(size: 9, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                Text(layout.profile == .n64 ? "N64 · DIGITAL STICK" : layout.profile.title.uppercased()).font(.system(size: 9, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
            }
        }
    }
    private var pairing: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 24) {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(mint)
                        .frame(width: 100, height: 100).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 28))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Every console. Your layout.").font(.system(size: 25, weight: .semibold, design: .rounded))
                        Text(controller.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Picker("Connection", selection: $useBluetooth) {
                            Text("Bluetooth").tag(true); Text("Wi-Fi").tag(false)
                        }.pickerStyle(.segmented).disabled(controller.connecting)
                        Button { scanning = true } label: { Label("Scan QR code", systemImage: "camera").font(.headline).padding(.vertical, 6) }
                            .buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(controller.connecting)
                    }
                }
                if controller.connecting { Button("Cancel connection") { controller.disconnect() } }
                if !useBluetooth { Button(manual ? "Hide manual connection" : "Connect manually") { manual.toggle() }.font(.caption) }
                if manual && !useBluetooth {
                    HStack {
                        TextField("Mac address", text: $address).keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().focused($editing)
                        TextField("Pairing code", text: $code).keyboardType(.numberPad).focused($editing)
                        Button("Connect") { editing = false; controller.connect(address: address, code: code) }
                            .disabled(address.isEmpty || code.count != 6 || controller.connecting)
                    }.textFieldStyle(.roundedBorder)
                }
                Text(useBluetooth ? "Keep Bluetooth on and allow Bluetooth access for DeltaPad or LiveContainer. You can stay on school Wi-Fi." : "Use the same private Wi-Fi or hotspot. Allow Camera and Local Network access in LiveContainer.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 680)
        }
    }
    private var controlCanvas: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scale = min(size.width / 800, size.height / 260)
            ZStack(alignment: .topLeading) {
                if customizing {
                    RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.025))
                    if snap {
                        Canvas { context, canvasSize in
                            var path = Path()
                            for x in stride(from: 0.0, through: canvasSize.width, by: gridSize) {
                                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: canvasSize.height))
                            }
                            for y in stride(from: 0.0, through: canvasSize.height, by: gridSize) {
                                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: canvasSize.width, y: y))
                            }
                            context.stroke(path, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
                        }.allowsHitTesting(false)
                    }
                }
                ForEach((customizing ? draft : layout.controls).filter { $0.id != "touchpad" || dsTouchpadEnabled }) { item in
                    let w = item.width * scale, h = item.height * scale
                    let centerX = ControlLayout.coordinate(item.x * size.width, extent: size.width, halfSize: w / 2, grid: nil) * size.width
                    let centerY = ControlLayout.coordinate(item.y * size.height, extent: size.height, halfSize: h / 2, grid: nil) * size.height
                    Group {
                        if customizing {
                            editorControl(item)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = item.id; inspectorPosition = nil }
                                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("layout"))
                                    .onChanged { value in
                                        selected = item.id
                                        guard let index = draft.firstIndex(where: { $0.id == item.id }) else { return }
                                        if dragStart == nil { dragStart = CGPoint(x: centerX, y: centerY) }
                                        guard let start = dragStart else { return }
                                        draft[index].x = ControlLayout.coordinate(start.x + value.translation.width, extent: size.width, halfSize: w / 2, grid: snap ? gridSize : nil)
                                        draft[index].y = ControlLayout.coordinate(start.y + value.translation.height, extent: size.height, halfSize: h / 2, grid: snap ? gridSize : nil)
                                    }.onEnded { _ in dragStart = nil })
                        } else {
                            liveControl(item, scale: scale).opacity(item.opacity)
                        }
                    }.frame(width: w, height: h).position(x: centerX, y: centerY)
                        .zIndex(customizing && selected == item.id ? 10 : item.isArea ? 0 : 1)
                }
                if customizing && inspector {
                    let panelHeight = min(238.0, size.height - 4)
                    let defaultX = draft[selectedIndex].x > 0.5 ? 134.0 : size.width - 134
                    let position = inspectorPosition ?? CGPoint(x: defaultX, y: size.height / 2)
                    let clamped = CGPoint(x: min(size.width - 130, max(130, position.x)), y: min(size.height - panelHeight / 2, max(panelHeight / 2, position.y)))
                    inspectorPanel(at: clamped, in: size, height: panelHeight)
                }
            }.coordinateSpace(name: "layout").clipped()
        }
    }
    @ViewBuilder private func liveControl(_ item: ControlLayout, scale: CGFloat) -> some View {
        if item.id == "joystick" {
            ThumbJoystick(accent: tint(item.tint)) { controller.joystick($0) }
        } else if item.id == "touchpad" {
            TouchSurface(accent: tint(item.tint), move: { controller.move($0) }, click: { controller.click() }, press: { controller.stylus($0) })
        } else {
            HoldButton(title: item.title, color: tint(item.tint), fontSize: (item.id.count == 1 ? 20 : 11) * max(0.8, scale)) { controller.button(item.id, down: $0) }
        }
    }
    private func editorControl(_ item: ControlLayout) -> some View {
        RoundedRectangle(cornerRadius: item.isArea ? 18 : 16)
            .fill(Color(uiColor: tint(item.tint)).opacity(item.opacity * (item.isArea ? 0.35 : 1)))
            .overlay {
                VStack(spacing: 4) {
                    if item.isArea { Image(systemName: item.id == "joystick" ? "move.3d" : "hand.draw").font(.title3) }
                    Text(item.title).font(.system(size: item.id.count == 1 ? 20 : 11, weight: .semibold, design: .rounded))
                }.foregroundStyle(.white)
            }
            .overlay { RoundedRectangle(cornerRadius: item.isArea ? 18 : 16).stroke(selected == item.id ? mint : .white.opacity(0.15), style: StrokeStyle(lineWidth: selected == item.id ? 2 : 1, dash: item.isArea ? [5, 4] : [])) }
    }
    private var recentColors: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(recentColorData.utf8))) ?? []
    }
    private func rememberColor(_ hex: String) {
        var colors = recentColors.filter { $0 != hex }; colors.insert(hex, at: 0)
        if let data = try? JSONEncoder().encode(Array(colors.prefix(7))), let text = String(data: data, encoding: .utf8) { recentColorData = text }
    }
    private func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
    private var selectedHSB: (h: Double, s: Double, b: Double) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tint(draft[selectedIndex].tint).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }
    private func applyColor(h: Double, s: Double, b: Double) {
        draft[selectedIndex].tint = hex(UIColor(hue: h, saturation: s, brightness: b, alpha: 1))
    }
    private func inspectorPanel(at center: CGPoint, in size: CGSize, height: CGFloat) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                Text(draft[selectedIndex].title).font(.caption.bold())
                Spacer()
                Button { inspector = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("layout"))
                    .onChanged { value in
                        if inspectorDragStart == nil { inspectorDragStart = center }
                        let start = inspectorDragStart ?? center
                        inspectorPosition = CGPoint(x: min(size.width - 130, max(130, start.x + value.translation.width)), y: min(size.height - height / 2, max(height / 2, start.y + value.translation.height)))
                    }.onEnded { _ in inspectorDragStart = nil })
            Picker("Inspector", selection: $inspectorTab) {
                Text("Size").tag(0); Text("Color").tag(1); Text("Haptics").tag(2)
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(spacing: 8) {
                    if inspectorTab == 0 {
                        compactSlider("Width", value: $draft[selectedIndex].width, range: draft[selectedIndex].isArea ? 100...360 : 28...160, suffix: "")
                        compactSlider("Height", value: $draft[selectedIndex].height, range: draft[selectedIndex].isArea ? 80...240 : 28...100, suffix: "")
                        compactSlider("Opacity", value: Binding(get: { draft[selectedIndex].opacity * 100 }, set: { draft[selectedIndex].opacity = $0 / 100 }), range: 25...100, suffix: "%")
                        HStack {
                            Text("Grid").font(.caption2)
                            Picker("Grid", selection: $gridSize) { Text("8").tag(8.0); Text("16").tag(16.0); Text("24").tag(24.0) }.pickerStyle(.segmented)
                            Button("Reset") {
                                if let original = layout.profile.defaults.first(where: { $0.id == selected }) { draft[selectedIndex] = original }
                            }.font(.caption2)
                        }
                    } else if inspectorTab == 1 {
                        HStack(spacing: 12) {
                            ColorWheel(hue: selectedHSB.h, saturation: selectedHSB.s, brightness: selectedHSB.b,
                                       changed: { h, s in applyColor(h: h, s: s, b: max(0.05, selectedHSB.b)) },
                                       ended: { rememberColor(hex(tint(draft[selectedIndex].tint))) })
                                .frame(width: 116, height: 116)
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: tint(draft[selectedIndex].tint))).frame(height: 32)
                                Text(hex(tint(draft[selectedIndex].tint))).font(.system(size: 10, design: .monospaced))
                                Text("Brightness").font(.caption2).foregroundStyle(.secondary)
                                Slider(value: Binding(get: { selectedHSB.b }, set: { applyColor(h: selectedHSB.h, s: selectedHSB.s, b: $0) }), in: 0...1,
                                       onEditingChanged: { if !$0 { rememberColor(hex(tint(draft[selectedIndex].tint))) } })
                            }
                        }
                        HStack(spacing: 7) {
                            Text("Recent").font(.system(size: 9)).foregroundStyle(.secondary)
                            if recentColors.isEmpty { Text("Colors appear here as you use them").font(.system(size: 9)).foregroundStyle(.secondary) }
                            ForEach(recentColors, id: \.self) { color in
                                Button { draft[selectedIndex].tint = color; rememberColor(color) } label: {
                                    Circle().fill(Color(uiColor: tint(color))).frame(width: 19, height: 19)
                                        .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                                }.accessibilityLabel("Recent color \(color)")
                            }
                        }
                    } else {
                        Toggle("Haptic feedback", isOn: $hapticsEnabled).font(.caption)
                        HStack { Text("Strength"); Spacer(); Text("\(Int(hapticStrength * 100))%").monospacedDigit() }.font(.caption)
                        Slider(value: $hapticStrength, in: 0.05...1, step: 0.05, onEditingChanged: { if !$0 { TouchFeedback.pulse() } }).disabled(!hapticsEnabled)
                        HStack { Text("Soft"); Spacer(); Text("Strong") }.font(.caption2).foregroundStyle(.secondary)
                        Button("Test haptics") { TouchFeedback.pulse() }.buttonStyle(.bordered).disabled(!hapticsEnabled)
                        Text("Saved automatically. Feel varies by iPhone.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.scrollIndicators(.hidden)
        }.padding(12).frame(width: 260, height: height)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
            .position(center).zIndex(100)
    }
    private func compactSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 10)).frame(width: 43, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue))\(suffix)").font(.system(size: 10, design: .monospaced)).frame(width: 34, alignment: .trailing)
        }
    }

}

@main struct DeltaPadPhoneApp: App { var body: some Scene { WindowGroup { PhoneView() } } }

final class JoystickView: UIView {
    var changed: ((Set<String>) -> Void)?
    private let base = UIView()
    private let knob = UIView()
    private let hint = UILabel()
    private var active: UITouch?
    private var origin = CGPoint.zero
    private var directions = Set<String>()
    private let travel: CGFloat = 48
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; clipsToBounds = true
        base.backgroundColor = UIColor.white.withAlphaComponent(0.07)
        base.layer.borderColor = UIColor.systemTeal.withAlphaComponent(0.4).cgColor
        base.layer.borderWidth = 2; base.layer.cornerRadius = 72
        base.isUserInteractionEnabled = false; base.isHidden = true
        knob.backgroundColor = .systemTeal; knob.layer.cornerRadius = 29
        knob.isUserInteractionEnabled = false; knob.isHidden = true
        hint.text = "Touch anywhere\nto move"
        hint.numberOfLines = 0; hint.textAlignment = .center
        hint.textColor = UIColor.white.withAlphaComponent(0.35); hint.font = .systemFont(ofSize: 12)
        addSubview(hint); addSubview(base); addSubview(knob)
        accessibilityLabel = "Floating movement joystick"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        hint.frame = bounds
        base.bounds = CGRect(x: 0, y: 0, width: 144, height: 144)
        knob.bounds = CGRect(x: 0, y: 0, width: 58, height: 58)
    }
    func setAccent(_ color: UIColor) {
        knob.backgroundColor = color
        base.layer.borderColor = color.withAlphaComponent(0.5).cgColor
        base.backgroundColor = color.withAlphaComponent(0.12)
    }
    func update(_ touch: UITouch) {
        let p = touch.location(in: self)
        let x = p.x - origin.x, y = p.y - origin.y
        let length = hypot(x, y), scale = length > travel ? travel / length : 1
        knob.center = CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        let next = joystickDirections(x: Double(x), y: Double(y), radius: Double(travel))
        if next != directions {
            if !next.isEmpty { TouchFeedback.pulse() }
            directions = next; changed?(next)
        }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard active == nil, let touch = touches.first else { return }
        active = touch; origin = touch.location(in: self)
        base.center = origin; knob.center = origin
        base.isHidden = false; knob.isHidden = false; hint.isHidden = true
        directions = []; changed?([]); TouchFeedback.pulse()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let active, touches.contains(active) { update(active) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let active, touches.contains(active) { reset() }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { reset() }
    func reset() {
        active = nil; directions = []; base.isHidden = true; knob.isHidden = true
        hint.isHidden = false; changed?([])
    }
    override func didMoveToWindow() { if window == nil { reset() } }
}
struct ThumbJoystick: UIViewRepresentable {
    var accent: UIColor = .systemTeal
    let changed: (Set<String>) -> Void
    func makeUIView(context: Context) -> JoystickView { let view = JoystickView(); view.changed = changed; view.setAccent(accent); return view }
    func updateUIView(_ view: JoystickView, context: Context) { view.changed = changed; view.setAccent(accent) }
}

final class TrackpadView: UIView {
    var accent: UIColor = .systemTeal { didSet { backgroundColor = accent.withAlphaComponent(dragging ? 0.25 : 0.10) } }
    var move: ((CGSize) -> Void)?
    var click: (() -> Void)?
    var press: ((Bool) -> Void)?
    private var last = CGPoint.zero
    private var start = CGPoint.zero
    private var beganAt: TimeInterval = 0
    private var moved = false
    private var dragging = false
    private var active: UITouch?
    private var hold: DispatchWorkItem?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.07); layer.cornerRadius = 18
        let label = UILabel(); label.numberOfLines = 0; label.textAlignment = .center
        label.text = "TOUCHPAD\nSlide to move · tap to click\nHold, then slide to drag"
        label.font = .systemFont(ofSize: 12); label.textColor = .lightGray
        label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor), label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16)])
        accessibilityLabel = "Touchpad. Tap to click; hold and move to drag."
    }
    required init?(coder: NSCoder) { fatalError() }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard active == nil, let touch = touches.first else { return }
        active = touch; start = touch.location(in: self); last = start
        moved = false; beganAt = touch.timestamp
        let hold = DispatchWorkItem { [weak self] in
            guard let self, self.active != nil, !self.moved else { return }
            self.dragging = true; TouchFeedback.pulse(); self.press?(true); self.backgroundColor = self.accent.withAlphaComponent(0.25)
        }
        self.hold = hold
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: hold)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active else { return }
        let p = active.location(in: self)
        if hypot(p.x - start.x, p.y - start.y) > 6 { moved = true; hold?.cancel() }
        // Ignore tiny tap jitter; retain all movement once the gesture becomes a slide.
        if moved || dragging { move?(CGSize(width: p.x - last.x, height: p.y - last.y)); last = p }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let active, !moved, !dragging, active.timestamp - beganAt < 0.35 { TouchFeedback.pulse(); click?() }
        reset()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { reset() }
    func reset() {
        hold?.cancel(); hold = nil; active = nil
        if dragging { press?(false) }; dragging = false
        backgroundColor = accent.withAlphaComponent(0.10)
    }
    override func didMoveToWindow() { if window == nil { reset() } }
}
struct TouchSurface: UIViewRepresentable {
    var accent: UIColor = .systemTeal
    let move: (CGSize) -> Void
    let click: () -> Void
    let press: (Bool) -> Void
    func makeUIView(context: Context) -> TrackpadView {
        let view = TrackpadView(); view.accent = accent; view.move = move; view.click = click; view.press = press; return view
    }
    func updateUIView(_ view: TrackpadView, context: Context) { view.accent = accent; view.move = move; view.click = click; view.press = press }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var found: ((PairingCode) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "DeltaPad.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private let message = UILabel()
    private var delivered = false
    private var stopped = false
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        message.text = "Point the camera at the QR code on your Mac"
        message.textColor = .white; message.numberOfLines = 0; message.textAlignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(message)
        NSLayoutConstraint.activate([message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), message.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)])
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async { if allowed { self?.configure() } else { self?.denied() } }
            }
        default: denied()
        }
    }
    func denied() { message.text = "Camera access is off. Enable Camera for LiveContainer (or DeltaPad) in Settings, then scan again. Manual pairing is also available." }
    func configure() {
        guard !stopped else { return }
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill
        self.preview = preview; view.layer.insertSublayer(preview, at: 0); preview.frame = view.bounds
        queue.async { [weak self] in
            guard let self else { return }
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else {
                DispatchQueue.main.async { self.message.text = "Camera unavailable. Use manual pairing." }; return
            }
            self.session.beginConfiguration(); self.session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard self.session.canAddOutput(output) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.message.text = "QR scanning unavailable. Use manual pairing." }; return
            }
            self.session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            self.session.commitConfiguration(); self.session.startRunning()
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); stop()
    }
    func stop() { stopped = true; let session = session; queue.async { session.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, !stopped, let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        guard let pair = PairingCode.parse(value) else { message.text = "This is not a DeltaPad pairing code."; return }
        delivered = true; stop(); found?(pair)
    }
}
struct QRScanner: UIViewControllerRepresentable {
    let found: (PairingCode) -> Void
    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController(); controller.found = found; return controller
    }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: QRScannerController, coordinator: ()) { controller.stop() }
}

struct ColorWheel: View {
    let hue: Double
    let saturation: Double
    let brightness: Double
    let changed: (Double, Double) -> Void
    let ended: () -> Void
    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) / 2
            ZStack {
                Circle().fill(AngularGradient(colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) }, center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
                Circle().fill(.black.opacity(1 - brightness))
                Circle().stroke(.white, lineWidth: 2).background(Circle().fill(.black.opacity(0.15)))
                    .frame(width: 12, height: 12)
                    .position(x: radius + cos(hue * 2 * .pi) * saturation * radius, y: radius + sin(hue * 2 * .pi) * saturation * radius)
            }.contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.location.x - radius, dy = value.location.y - radius
                        let angle = atan2(dy, dx) / (2 * .pi)
                        changed(angle < 0 ? angle + 1 : angle, min(1, hypot(dx, dy) / radius))
                    }.onEnded { _ in ended() })
                .accessibilityLabel("Color wheel")
        }
    }
}
