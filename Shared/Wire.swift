import Foundation
import Network

struct Packet: Codable {
    var profile: String? = nil
    var kind: String
    var code: String? = nil
    var buttons: [String]? = nil
    var dx: Double? = nil
    var dy: Double? = nil
    var down: Bool? = nil
}

// All callbacks run on the main queue. Newline-delimited JSON; bounded input.
final class Wire {
    let connection: NWConnection
    var buffer = Data()
    var onPacket: ((Packet) -> Void)?
    var onClose: (() -> Void)?
    var closed = false
    var closeReason = "The other device closed the connection."
    var onWaiting: ((String) -> Void)?
    init(_ connection: NWConnection) { self.connection = connection }
    func start(ready: (() -> Void)? = nil) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: ready?(); self.receive()
            case .failed(let error): self.close(reason: "Network error: \(error)")
            case .waiting(let error): self.onWaiting?("Network waiting: \(error)")
            case .cancelled: self.close()
            default: break
            }
        }
        connection.start(queue: .main)
    }
    func send(_ packet: Packet) {
        guard !closed, var data = try? JSONEncoder().encode(packet) else { return }
        data.append(10)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.close(reason: "Send failed: \(error)") }
        })
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            guard self.buffer.count <= 16384 else { self.close(); return }
            while let end = self.buffer.firstIndex(of: 10) {
                let line = self.buffer[..<end]
                guard let packet = try? JSONDecoder().decode(Packet.self, from: line) else {
                    self.close(); return
                }
                self.buffer.removeSubrange(...end)
                self.onPacket?(packet)
                if self.closed { return }
            }
            if let error { self.close(reason: "Receive failed: \(error)") }
            else if complete { self.close() } else { self.receive() }
        }
    }
    func sendThenClose(_ packet: Packet, reason: String) {
        guard !closed, var data = try? JSONEncoder().encode(packet) else { return }
        data.append(10)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.close(reason: reason)
        })
    }
    func close(reason: String? = nil) {
        if let reason { closeReason = reason }
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }
}

struct PairingCode: Codable {
    let app: String
    let version: Int
    let address: String
    let code: String
    var bluetooth: String? = nil
    init(address: String, code: String, bluetooth: String? = nil) {
        self.app = "DeltaPad"; self.version = 1; self.address = address; self.code = code; self.bluetooth = bluetooth
    }
    var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func parse(_ value: String) -> PairingCode? {
        guard value.utf8.count < 1024, let data = value.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Self.self, from: data),
              payload.app == "DeltaPad", payload.version == 1,
              payload.bluetooth == nil || UUID(uuidString: payload.bluetooth!) != nil,
              IPv4Address(payload.address) != nil,
              payload.code.count == 6, payload.code.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return payload
    }
}

func joystickDirections(x: Double, y: Double, radius: Double) -> Set<String> {
    let distance = hypot(x, y)
    guard radius > 0, distance > radius * 0.18 else { return [] }
    var result = Set<String>()
    let threshold = distance * sin(Double.pi / 8)
    if abs(x) > threshold { result.insert(x > 0 ? "right" : "left") }
    if abs(y) > threshold { result.insert(y > 0 ? "down" : "up") }
    return result
}

struct ControlLayout: Codable, Identifiable, Equatable {
    var id: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var opacity: Double = 1
    var tint: String = "slate"
    var isArea: Bool { id == "joystick" || id == "touchpad" }
    var title: String {
        let names = ["joystick": "Joystick", "touchpad": "Touchpad", "up": "↑", "down": "↓", "left": "←", "right": "→", "cUp": "C ↑", "cDown": "C ↓", "cLeft": "C ←", "cRight": "C →"]
        return names[id] ?? id.uppercased()
    }
    static let defaults: [ControlLayout] = [
        .init(id: "joystick", x: 0.19, y: 0.58, width: 280, height: 202, tint: "mint"),
        .init(id: "touchpad", x: 0.51, y: 0.50, width: 190, height: 158, opacity: 0.9, tint: "mint"),
        .init(id: "L", x: 0.12, y: 0.10, width: 116, height: 38),
        .init(id: "R", x: 0.88, y: 0.10, width: 116, height: 38),
        .init(id: "X", x: 0.83, y: 0.33, width: 54, height: 54, tint: "violet"),
        .init(id: "Y", x: 0.745, y: 0.56, width: 54, height: 54, tint: "violet"),
        .init(id: "A", x: 0.915, y: 0.56, width: 54, height: 54, tint: "mint"),
        .init(id: "B", x: 0.83, y: 0.79, width: 54, height: 54, tint: "mint"),
        .init(id: "menu", x: 0.40, y: 0.91, width: 68, height: 30),
        .init(id: "select", x: 0.51, y: 0.91, width: 68, height: 30),
        .init(id: "start", x: 0.62, y: 0.91, width: 68, height: 30)
    ]
    static func restored(_ data: Data?, defaults: [ControlLayout] = ControlLayout.defaults) -> [ControlLayout] {
        guard let data, let decoded = try? JSONDecoder().decode([ControlLayout].self, from: data),
              decoded.count == defaults.count, Set(decoded.map(\.id)) == Set(defaults.map(\.id)),
              decoded.allSatisfy({ [$0.x, $0.y, $0.width, $0.height, $0.opacity].allSatisfy(\.isFinite) }) else { return defaults }
        return decoded.map { item in
            var item = item
            item.x = min(1, max(0, item.x)); item.y = min(1, max(0, item.y))
            item.width = min(item.isArea ? 360 : 160, max(item.isArea ? 100 : 28, item.width))
            item.height = min(item.isArea ? 240 : 100, max(item.isArea ? 80 : 28, item.height))
            item.opacity = min(1, max(0.25, item.opacity)); return item
        }
    }
    static func coordinate(_ value: Double, extent: Double, halfSize: Double, grid: Double?) -> Double {
        guard extent > 0 else { return 0.5 }
        let snapped = grid.map { (value / $0).rounded() * $0 } ?? value
        let margin = min(extent / 2, halfSize)
        return min(extent - margin, max(margin, snapped)) / extent
    }
}

enum ControllerProfile: String, Codable, CaseIterable, Identifiable {
    case nesGbc, gba, snesDs, n64
    var id: String { rawValue }
    var title: String {
        switch self { case .nesGbc: return "NES / GBC"; case .gba: return "GBA"; case .snesDs: return "SNES / DS"; case .n64: return "N64" }
    }
    var defaults: [ControlLayout] {
        switch self {
        case .snesDs: return ControlLayout.defaults
        case .nesGbc, .gba:
            let keep: Set<String> = self == .gba ? ["joystick", "A", "B", "L", "R", "menu", "select", "start"] : ["joystick", "A", "B", "menu", "select", "start"]
            return ControlLayout.defaults.filter { keep.contains($0.id) }.map { item in
                var item = item
                if item.id == "A" { item.x = 0.85; item.y = 0.45; item.width = 66; item.height = 66 }
                if item.id == "B" { item.x = 0.73; item.y = 0.66; item.width = 66; item.height = 66 }
                if item.id == "joystick" { item.x = 0.23; item.width = 330 }
                return item
            }
        case .n64:
            return [
                .init(id: "joystick", x: 0.19, y: 0.58, width: 270, height: 200, tint: "mint"),
                .init(id: "L", x: 0.12, y: 0.10, width: 110, height: 36),
                .init(id: "R", x: 0.88, y: 0.10, width: 110, height: 36),
                .init(id: "Z", x: 0.46, y: 0.10, width: 94, height: 36, tint: "violet"),
                .init(id: "up", x: 0.47, y: 0.34, width: 34, height: 34),
                .init(id: "down", x: 0.47, y: 0.66, width: 34, height: 34),
                .init(id: "left", x: 0.415, y: 0.50, width: 34, height: 34),
                .init(id: "right", x: 0.525, y: 0.50, width: 34, height: 34),
                .init(id: "cUp", x: 0.84, y: 0.30, width: 42, height: 42, tint: "gold"),
                .init(id: "cDown", x: 0.84, y: 0.64, width: 42, height: 42, tint: "gold"),
                .init(id: "cLeft", x: 0.775, y: 0.47, width: 42, height: 42, tint: "gold"),
                .init(id: "cRight", x: 0.905, y: 0.47, width: 42, height: 42, tint: "gold"),
                .init(id: "A", x: 0.71, y: 0.78, width: 58, height: 58, tint: "blue"),
                .init(id: "B", x: 0.65, y: 0.51, width: 52, height: 52, tint: "mint"),
                .init(id: "menu", x: 0.42, y: 0.91, width: 68, height: 30),
                .init(id: "start", x: 0.54, y: 0.91, width: 68, height: 30, tint: "coral")
            ]
        }
    }
    var keyboardMapping: String {
        switch self {
        case .nesGbc: return "Joystick / D-pad → Arrow keys\nA → X    B → Z\nStart → Return    Select → Tab    Menu → Escape"
        case .gba: return "Joystick / D-pad → Arrow keys\nA → X    B → Z    L → Q    R → W\nStart → Return    Select → Tab    Menu → Escape"
        case .snesDs: return "Joystick / D-pad → Arrow keys\nA → X    B → Z    X → S    Y → A\nL → Q    R → W\nStart → Return    Select → Tab    Menu → Escape"
        case .n64: return "Stick ↑ / ↓ / ← / → → I / K / J / L\nD-pad → Arrow keys\nC ↑ / ↓ / ← / → → T / G / F / H\nA → X    B → Z    Z trigger → E\nL → Q    R → W    Start → Return\nMenu → Escape"
        }
    }
}

// Portable settings only: never includes network addresses or pairing codes.
struct ControllerConfig: Codable {
    var format = "DeltaPad.controller-config"
    var version = 1
    var selectedProfile: ControllerProfile
    var layouts: [String: [ControlLayout]]
    var hapticsEnabled: Bool
    var hapticStrength: Double
    var dsTouchpadEnabled: Bool
    var snapToGrid: Bool
    var gridSpacing: Double
    var recentColors: [String]

    static func validColor(_ value: String) -> Bool {
        ["slate", "mint", "violet", "gold", "coral", "blue"].contains(value) ||
        (value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit })
    }
    static func read(_ data: Data) throws -> Self {
        guard data.count <= 1_000_000 else { throw ConfigError.invalid }
        let config: Self
        do { config = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ConfigError.invalid }
        guard config.format == "DeltaPad.controller-config" else { throw ConfigError.invalid }
        guard config.version == 1 else { throw ConfigError.version }
        guard Set(config.layouts.keys) == Set(ControllerProfile.allCases.map(\.rawValue)),
              config.hapticStrength.isFinite, (0.05...1).contains(config.hapticStrength),
              [8.0, 16.0, 24.0].contains(config.gridSpacing),
              config.recentColors.count <= 7, config.recentColors.allSatisfy(validColor) else { throw ConfigError.invalid }
        for profile in ControllerProfile.allCases {
            guard let items = config.layouts[profile.rawValue], items.count == profile.defaults.count,
                  Set(items.map(\.id)) == Set(profile.defaults.map(\.id)),
                  items.allSatisfy({ item in
                      [item.x, item.y, item.width, item.height, item.opacity].allSatisfy(\.isFinite) &&
                      (0...1).contains(item.x) && (0...1).contains(item.y) &&
                      (item.isArea ? 100.0...360.0 : 28.0...160.0).contains(item.width) &&
                      (item.isArea ? 80.0...240.0 : 28.0...100.0).contains(item.height) &&
                      (0.25...1).contains(item.opacity) && validColor(item.tint)
                  }) else { throw ConfigError.invalid }
        }
        return config
    }
    enum ConfigError: LocalizedError {
        case invalid, version
        var errorDescription: String? {
            switch self {
            case .invalid: return "This file is not a valid DeltaPad controller config. Your settings have not changed."
            case .version: return "This config uses an unsupported version. Update DeltaPad before importing it."
            }
        }
    }
}
