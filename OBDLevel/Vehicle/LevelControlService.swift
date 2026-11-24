import Foundation

// MARK: - Enums

/// Which corner a height channel belongs to. The first four channels map to these in order.
enum WheelSlot: Int, CaseIterable, Codable, Hashable {
    case frontLeft = 0
    case frontRight
    case rearLeft
    case rearRight

    var title: String {
        switch self {
        case .frontLeft: return "Vänster fram"
        case .frontRight: return "Höger fram"
        case .rearLeft: return "Vänster bak"
        case .rearRight: return "Höger bak"
        }
    }

    var axle: Axle {
        (self == .frontLeft || self == .frontRight) ? .front : .rear
    }
}

enum Axle: String, Hashable {
    case front
    case rear

    var title: String { self == .front ? "fram" : "bak" }
}

enum VentTarget: String, CaseIterable, Hashable {
    case front
    case rear
    case both

    var title: String {
        switch self {
        case .front: return "Lufta \(Axle.front.title)"
        case .rear: return "Lufta \(Axle.rear.title)"
        case .both: return "Lufta båda"
        }
    }

    var buttonTitle: String {
        switch self {
        case .front: return "Vent fram"
        case .rear: return "Vent bak"
        case .both: return "Vent båda"
        }
    }

    var axles: [Axle] {
        switch self {
        case .front: return [.front]
        case .rear: return [.rear]
        case .both: return [.front, .rear]
        }
    }
}

/// What a routine does. The interface maps buttons to routines through these roles,
/// so the same RID list works no matter what the ODX pack calls them.
enum ActionRole: String, Codable, CaseIterable, Identifiable, Hashable {
    case ventFront
    case ventRear
    case levelOff
    case levelOn
    case reservoirFill
    case reservoirVent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ventFront: return "Vent fram"
        case .ventRear: return "Vent bak"
        case .levelOff: return "Nivåreglering av"
        case .levelOn: return "Nivåreglering på"
        case .reservoirFill: return "Fyll behållare"
        case .reservoirVent: return "Lufta behållare"
        }
    }
}

// MARK: - Models

struct HeightChannel: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var did: UInt16
    var length: Int
    var scale: Double
    var offset: Double
    var signed: Bool
    var unit: String?

    func decode(_ data: [UInt8]) -> Double? {
        guard data.count >= length, length > 0, length <= 4 else { return nil }
        var raw: UInt32 = 0
        for i in 0..<length { raw = (raw << 8) | UInt32(data[i]) }

        let value: Double
        if signed {
            let bits = length * 8
            let signBit = UInt32(1) << (bits - 1)
            if raw & signBit != 0 {
                let signedValue = Int64(raw) - (Int64(1) << bits)
                value = Double(signedValue)
            } else {
                value = Double(raw)
            }
        } else {
            value = Double(raw)
        }
        return value * scale + offset
    }
}

struct RoutineAction: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var rid: UInt16
    var parameters: [UInt8]
    var confirm: Bool = true
    var role: ActionRole?
}

struct LevelProfile: Codable {
    var name: String
    var vehicle: String?
    var txId: UInt32
    var rxId: UInt32
    var channels: [HeightChannel]
    var actions: [RoutineAction]

    static let blank = LevelProfile(
        name: "Min bil",
        vehicle: "Luftfjädring · UDS",
        txId: 0x714,
        rxId: 0x77E,
        channels: [
            HeightChannel(name: "Vänster fram", did: 0x0000, length: 2, scale: 0.1, offset: 0, signed: true, unit: "mm"),
            HeightChannel(name: "Höger fram", did: 0x0000, length: 2, scale: 0.1, offset: 0, signed: true, unit: "mm"),
            HeightChannel(name: "Vänster bak", did: 0x0000, length: 2, scale: 0.1, offset: 0, signed: true, unit: "mm"),
            HeightChannel(name: "Höger bak", did: 0x0000, length: 2, scale: 0.1, offset: 0, signed: true, unit: "mm"),
            HeightChannel(name: "Systemtryck", did: 0x0000, length: 2, scale: 0.1, offset: 0, signed: false, unit: "bar"),
            HeightChannel(name: "Kompressortemperatur", did: 0x0000, length: 1, scale: 1, offset: 0, signed: false, unit: "°C")
        ],
        actions: [
            RoutineAction(name: "Vent fram", rid: 0x0000, parameters: [], role: .ventFront),
            RoutineAction(name: "Vent bak", rid: 0x0000, parameters: [], role: .ventRear),
            RoutineAction(name: "Nivåreglering av", rid: 0x0000, parameters: [], role: .levelOff),
            RoutineAction(name: "Nivåreglering på", rid: 0x0000, parameters: [], role: .levelOn),
            RoutineAction(name: "Fyll behållare", rid: 0x0000, parameters: [], role: .reservoirFill),
            RoutineAction(name: "Lufta behållare", rid: 0x0000, parameters: [], role: .reservoirVent)
        ]
    )
}

struct HeightReading: Identifiable {
    let id = UUID()
    let name: String
    let did: UInt16
    var value: Double?
    var raw: String
}

// MARK: - Service

final class LevelControlService: ObservableObject {

    @Published var profile: LevelProfile {
        didSet { persist() }
    }
    @Published var readings: [HeightReading] = []
    @Published var busy = false
    @Published var statusLine = ""
    @Published var discoveredDIDs: [String] = []
    @Published var discoveredRoutines: [String] = []
    /// The app's own belief about level control. The ECU is not read for this.
    @Published var levelControlEnabled = true

    let transport: OBDelevenTransport
    let ecu: ECUConnection

    private let storeKey = "level.profile.v1"

    init(transport: OBDelevenTransport) {
        self.transport = transport
        self.ecu = ECUConnection(transport: transport)

        if let data = UserDefaults.standard.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode(LevelProfile.self, from: data) {
            profile = saved
        } else {
            profile = .blank
        }
        Self.migrate(&profile)
        readings = profile.channels.map {
            HeightReading(name: $0.name, did: $0.did, value: nil, raw: "–")
        }
    }

    /// Older profiles stored channels without units and routines without roles.
    /// Roles used to be implied by the routine name, so bake that in once.
    private static func migrate(_ profile: inout LevelProfile) {
        // Only legacy profiles (created before roles existed) have no roles at all.
        guard profile.actions.allSatisfy({ $0.role == nil }) else { return }
        for i in profile.actions.indices {
            let name = profile.actions[i].name.lowercased()
            if name.contains("vent") && name.contains("front") {
                profile.actions[i].role = .ventFront
            } else if name.contains("vent") && name.contains("rear") {
                profile.actions[i].role = .ventRear
            } else if name.contains("level") && name.hasSuffix("off") {
                profile.actions[i].role = .levelOff
            } else if name.contains("level") && name.hasSuffix("on") {
                profile.actions[i].role = .levelOn
            } else if name.contains("fill") {
                profile.actions[i].role = .reservoirFill
            } else if name.contains("vent") && name.contains("reservoir") {
                profile.actions[i].role = .reservoirVent
            }
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    // MARK: Connection

    func connectECU() async {
        await run("connecting") {
            self.ecu.txId = self.profile.txId
            self.ecu.rxId = self.profile.rxId
            try await self.ecu.open()
            self.statusLine = "ECU open"
        }
    }

    // MARK: Self test

    /// Runs the whole ladder and reports where it stops: protocol, CAN ids, generation,
    /// extended session, tester present.
    func runSelfTest() async {
        await run("självtest") {
            var lines: [String] = []
            do {
                try await self.transport.setProtocol(.isoTP)
                lines.append("20 02 ok")

                let gen = try await self.transport.readGeneration()
                lines.append("generation \(gen)")

                try await self.transport.setCAN(tx: self.profile.txId, rx: self.profile.rxId)
                lines.append(String(format: "CAN %03X→%03X ok", self.profile.txId, self.profile.rxId))

                let session = try await self.ecu.send([0x10, 0x03])
                lines.append("10 03 → " + session.hex)

                let alive = try await self.ecu.send([0x3E, 0x00])
                lines.append("3E 00 → " + alive.hex)
            } catch {
                lines.append("stopp: " + error.localizedDescription)
            }
            self.statusLine = lines.joined(separator: " · ")
        }
    }

    // MARK: Heights

    func readHeights() async {
        await run("reading heights") {
            var out: [HeightReading] = []
            for channel in self.profile.channels {
                guard channel.did != 0 else {
                    out.append(HeightReading(name: channel.name, did: 0, value: nil, raw: "no DID"))
                    continue
                }
                do {
                    let data = try await self.ecu.readDID(channel.did)
                    let value = channel.decode(data)
                    out.append(HeightReading(name: channel.name,
                                             did: channel.did,
                                             value: value,
                                             raw: data.hex))
                } catch {
                    out.append(HeightReading(name: channel.name,
                                             did: channel.did,
                                             value: nil,
                                             raw: "err \(error.localizedDescription)"))
                }
            }
            self.readings = out
            let summary = out.compactMap { $0.value }.map { String(format: "%.1f", $0) }.joined(separator: " / ")
            self.statusLine = summary.isEmpty ? "no values decoded" : summary
        }
    }

    // MARK: Channel and routine helpers

    var wheelChannels: [HeightChannel] { Array(profile.channels.prefix(4)) }
    var systemChannels: [HeightChannel] { Array(profile.channels.dropFirst(4)) }

    func action(for role: ActionRole) -> RoutineAction? {
        profile.actions.first { $0.role == role }
    }

    func hasRoutine(_ role: ActionRole) -> Bool {
        (action(for: role)?.rid ?? 0) != 0
    }

    func assign(_ role: ActionRole, to id: UUID?) {
        if let index = profile.actions.firstIndex(where: { $0.role == role }) {
            profile.actions[index].role = nil
        }
        if let id, let index = profile.actions.firstIndex(where: { $0.id == id }) {
            profile.actions[index].role = role
        }
    }

    func rebuildReadings() {
        readings = profile.channels.map {
            HeightReading(name: $0.name, did: $0.did, value: nil, raw: "–")
        }
    }

    func addChannel() {
        profile.channels.append(
            HeightChannel(name: "Ny kanal", did: 0x0000, length: 2, scale: 0.1,
                          offset: 0, signed: false, unit: nil)
        )
        rebuildReadings()
    }

    func removeChannel(_ id: UUID) {
        profile.channels.removeAll { $0.id == id }
        rebuildReadings()
    }

    func resetProfile() {
        profile = .blank
        levelControlEnabled = true
        rebuildReadings()
        statusLine = "Profilen är återställd"
    }

    // MARK: Actions

    @discardableResult
    func runAction(_ action: RoutineAction) async -> Bool {
        guard action.rid != 0 else {
            statusLine = "\(action.name): RID saknas i Inställningar"
            return false
        }
        return await run(action.name) {
            let result = try await self.ecu.runRoutine(action.rid,
                                                       parameters: action.parameters) { msg in
                self.statusLine = "\(action.name): \(msg)"
            }
            self.statusLine = "\(action.name): klar \(result.hex)"
        }
    }

    func stopAction(_ action: RoutineAction) async {
        guard action.rid != 0 else { return }
        await run("stoppar") {
            _ = try await self.ecu.stopRoutine(action.rid)
            self.statusLine = "\(action.name): stoppad"
        }
    }

    func setLevelControl(_ on: Bool) async {
        let role: ActionRole = on ? .levelOn : .levelOff
        guard let routine = action(for: role), routine.rid != 0 else {
            statusLine = "Nivåreglering \(on ? "på" : "av"): RID saknas (Inställningar → Funktionsmappning)"
            return
        }
        levelControlEnabled = on
        let ok = await runAction(routine)
        if !ok {
            levelControlEnabled = !on
            statusLine = "Nivåreglering: misslyckades, läget återställt"
        }
    }

    func canVent(_ target: VentTarget) -> Bool {
        switch target {
        case .front: return hasRoutine(.ventFront)
        case .rear: return hasRoutine(.ventRear)
        case .both: return hasRoutine(.ventFront) && hasRoutine(.ventRear)
        }
    }

    func vent(_ target: VentTarget) async {
        let roles: [ActionRole] = target == .front ? [.ventFront]
            : target == .rear ? [.ventRear]
            : [.ventFront, .ventRear]

        var missing: [String] = []
        var routines: [RoutineAction] = []
        for role in roles {
            if let routine = action(for: role), routine.rid != 0 {
                routines.append(routine)
            } else {
                missing.append(role.title)
            }
        }
        guard missing.isEmpty else {
            statusLine = "Luftning: RID saknas för " + missing.joined(separator: ", ")
            return
        }
        for routine in routines {
            let ok = await runAction(routine)
            if !ok { return }
        }
        statusLine = "Luftning klar (\(target.title.lowercased()))"
    }

    func reservoir(_ role: ActionRole) async {
        guard let routine = action(for: role), routine.rid != 0 else {
            statusLine = "\(role.title): RID saknas i Inställningar"
            return
        }
        _ = await runAction(routine)
    }

    func rawCommand(_ hex: String) async {
        guard let bytes = hex.hexBytes, !bytes.isEmpty else {
            statusLine = "bad hex"
            return
        }
        await run("raw") {
            let response = try await self.ecu.send(bytes)
            self.statusLine = "response " + response.hex
            self.transport.note("raw " + hex.uppercased() + " -> " + response.hex)
        }
    }

    // MARK: Discovery

    func scanDIDs(from start: UInt16, count: Int) async {
        await run("scanning DIDs") {
            self.discoveredDIDs.removeAll()
            for i in 0..<count {
                let did = start &+ UInt16(i)
                do {
                    let data = try await self.ecu.readDID(did)
                    guard !data.isEmpty else { continue }
                    let line = String(format: "%04X: %@", did, data.hex)
                    self.discoveredDIDs.append(line)
                } catch {
                    continue
                }
            }
            self.statusLine = "\(self.discoveredDIDs.count) DIDs answered"
        }
    }

    func scanRoutines(from start: UInt16, count: Int) async {
        await run("scanning routines") {
            self.discoveredRoutines.removeAll()
            for i in 0..<count {
                let rid = start &+ UInt16(i)
                do {
                    let response = try await self.ecu.routineResults(rid)
                    self.discoveredRoutines.append(String(format: "%04X: %@", rid, response.hex))
                } catch {
                    continue
                }
                if i % 8 == 0 { try? await Task.sleep(nanoseconds: 40_000_000) }
            }
            self.statusLine = "\(self.discoveredRoutines.count) routines responded"
        }
    }

    // MARK: Plumbing

    @discardableResult
    private func run(_ label: String, _ body: @escaping () async throws -> Void) async -> Bool {
        guard !busy else {
            statusLine = "upptagen: \(label)"
            return false
        }
        busy = true
        statusLine = label
        defer { busy = false }
        do {
            try await body()
            return true
        } catch {
            statusLine = "\(label): \(error.localizedDescription)"
            return false
        }
    }
}
