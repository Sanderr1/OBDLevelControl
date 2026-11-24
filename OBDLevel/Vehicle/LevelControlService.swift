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
    var heading: String { self == .front ? "Fram" : "Bak" }
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
    case raiseFront
    case lowerFront
    case raiseRear
    case lowerRear
    case ventFront
    case ventRear
    case levelOff
    case levelOn
    case reservoirFill
    case reservoirVent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .raiseFront: return "Höj fram"
        case .lowerFront: return "Sänk fram"
        case .raiseRear: return "Höj bak"
        case .lowerRear: return "Sänk bak"
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
    /// Which channel shows the battery voltage. Optional so older profiles still decode.
    var battery: UUID?

    /// The measuring values the EV_AirSuspe unit (Audi A6 C7 air suspension) lists,
    /// in the order OBDeleven shows them. The numbers are DIDs and do not change;
    /// only the names come from the ODX pack.
    static let knownDIDs: [(name: String, did: UInt16, length: Int, scale: Double, unit: String?)] = [
        ("Vänster fram", 0x258F, 2, 0.1, "mm"),
        ("Höger fram", 0x2590, 2, 0.1, "mm"),
        ("Vänster bak", 0x2591, 2, 0.1, "mm"),
        ("Höger bak", 0x2592, 2, 0.1, "mm"),
        ("Systemtryck", 0x2B83, 2, 0.01, "bar")
    ]

    static var blank: LevelProfile {
        let battery = HeightChannel(name: "Batterispänning", did: 0x0000, length: 2,
                                    scale: 0.001, offset: 0, signed: false, unit: "V")
        return LevelProfile(
            name: "Min bil",
            vehicle: "Luftfjädring · UDS",
            txId: 0x714,
            rxId: 0x77E,
            channels: [
                HeightChannel(name: "Vänster fram", did: 0x258F, length: 2, scale: 0.1, offset: 0, signed: false, unit: "mm"),
                HeightChannel(name: "Höger fram", did: 0x2590, length: 2, scale: 0.1, offset: 0, signed: false, unit: "mm"),
                HeightChannel(name: "Vänster bak", did: 0x2591, length: 2, scale: 0.1, offset: 0, signed: false, unit: "mm"),
                HeightChannel(name: "Höger bak", did: 0x2592, length: 2, scale: 0.1, offset: 0, signed: false, unit: "mm"),
                HeightChannel(name: "Systemtryck", did: 0x2B83, length: 2, scale: 0.01, offset: 0, signed: false, unit: "bar"),
                HeightChannel(name: "Kompressortemperatur", did: 0x0000, length: 1, scale: 1, offset: 0, signed: false, unit: "°C"),
                battery
            ],
            actions: [
                RoutineAction(name: "Höj fram", rid: 0x0000, parameters: [], role: .raiseFront),
                RoutineAction(name: "Sänk fram", rid: 0x0000, parameters: [], role: .lowerFront),
                RoutineAction(name: "Höj bak", rid: 0x0000, parameters: [], role: .raiseRear),
                RoutineAction(name: "Sänk bak", rid: 0x0000, parameters: [], role: .lowerRear),
                RoutineAction(name: "Vent fram", rid: 0x0000, parameters: [], role: .ventFront),
                RoutineAction(name: "Vent bak", rid: 0x0000, parameters: [], role: .ventRear),
                RoutineAction(name: "Nivåreglering av", rid: 0x0000, parameters: [], role: .levelOff),
                RoutineAction(name: "Nivåreglering på", rid: 0x0000, parameters: [], role: .levelOn),
                RoutineAction(name: "Fyll behållare", rid: 0x0000, parameters: [], role: .reservoirFill),
                RoutineAction(name: "Lufta behållare", rid: 0x0000, parameters: [], role: .reservoirVent)
            ],
            battery: battery.id
        )
    }
}

/// Ranges used by the automatic id search. Stored separately from the profile so
/// adding fields here can never break an older saved profile.
struct AutoSettings: Codable {
    var didStart: UInt16 = 0x0000
    var didCount: Int = 256
    var ridStart: UInt16 = 0x0000
    var ridCount: Int = 256
    var onConnect = true
    /// Replace channels that already have a DID instead of only filling empty ones.
    var overwriteExisting = false

    init() {}

    /// Reads whatever an older stored copy has and defaults the rest, so adding a
    /// field here never throws away the saved ranges.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        didStart = try c.decodeIfPresent(UInt16.self, forKey: .didStart) ?? 0x0000
        didCount = try c.decodeIfPresent(Int.self, forKey: .didCount) ?? 256
        ridStart = try c.decodeIfPresent(UInt16.self, forKey: .ridStart) ?? 0x0000
        ridCount = try c.decodeIfPresent(Int.self, forKey: .ridCount) ?? 256
        onConnect = try c.decodeIfPresent(Bool.self, forKey: .onConnect) ?? true
        overwriteExisting = try c.decodeIfPresent(Bool.self, forKey: .overwriteExisting) ?? false
    }
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
    @Published var autoSettings: AutoSettings {
        didSet { persistAuto() }
    }
    /// Progress of a running automatic id search, e.g. "0A31  (412/1024)".
    @Published var autoProgress = ""
    /// The app's own belief about level control. The ECU is not read for this.
    @Published var levelControlEnabled = true
    /// Last routine started, so "Stoppa" knows what to abort.
    @Published private(set) var lastAction: RoutineAction?
    /// True only while a routine is actually being started/polled.
    @Published private(set) var canStop = false

    let transport: OBDelevenTransport
    let ecu: ECUConnection

    private let storeKey = "level.profile.v1"
    private let autoKey = "level.auto.v1"
    private var stopRequested = false

    init(transport: OBDelevenTransport) {
        self.transport = transport
        self.ecu = ECUConnection(transport: transport)

        if let data = UserDefaults.standard.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode(LevelProfile.self, from: data) {
            profile = saved
        } else {
            profile = .blank
        }
        if let data = UserDefaults.standard.data(forKey: autoKey),
           let saved = try? JSONDecoder().decode(AutoSettings.self, from: data) {
            autoSettings = saved
        } else {
            autoSettings = AutoSettings()
        }
        Self.migrate(&profile)
        readings = profile.channels.map {
            HeightReading(name: $0.name, did: $0.did, value: nil, raw: "–")
        }
    }

    /// Older profiles stored channels without units, routines without roles and had no
    /// battery channel. Roles used to be implied by the routine name, so bake that in once.
    private static func migrate(_ profile: inout LevelProfile) {
        if profile.actions.allSatisfy({ $0.role == nil }) {
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

        // Every profile gets exactly one battery channel, once.
        if let id = profile.battery, profile.channels.contains(where: { $0.id == id }) { return }
        if let existing = profile.channels.first(where: {
            ($0.unit ?? "").uppercased() == "V" || $0.name.lowercased().contains("batteri")
        }) {
            profile.battery = existing.id
            return
        }
        let channel = HeightChannel(name: "Batterispänning", did: 0x0000, length: 2,
                                    scale: 0.001, offset: 0, signed: false, unit: "V")
        profile.channels.append(channel)
        profile.battery = channel.id
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    private func persistAuto() {
        guard let data = try? JSONEncoder().encode(autoSettings) else { return }
        UserDefaults.standard.set(data, forKey: autoKey)
    }

    // MARK: Connection

    func connectECU() async {
        let ok = await run("kopplar upp") {
            self.ecu.txId = self.profile.txId
            self.ecu.rxId = self.profile.rxId
            try await self.ecu.open()
            self.statusLine = "Styrenhet öppen"
        }
        guard ok, autoSettings.onConnect, needsAutoConfig else { return }
        await autoConfigure()
    }

    /// True while any channel still lacks a DID or any routine lacks a RID.
    /// Used to avoid re-scanning an already configured car on every connect.
    var needsAutoConfig: Bool {
        profile.channels.contains { $0.did == 0 } || profile.actions.contains { $0.rid == 0 }
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

    // MARK: Automatic configuration

    /// Writes the known DID map for EV_AirSuspe 003024 into the profile.
    /// These come from the measuring values the module itself lists — the numbers are
    /// fixed for that control unit, only the labels come from the ODX pack.
    func applyKnownDIDs() {
        var updated = profile
        var lines: [String] = []
        for (index, known) in LevelProfile.knownDIDs.enumerated() where index < updated.channels.count {
            updated.channels[index].did = known.did
            updated.channels[index].length = known.length
            updated.channels[index].scale = known.scale
            updated.channels[index].offset = 0
            updated.channels[index].signed = false
            updated.channels[index].unit = known.unit
            lines.append(String(format: "%@ %04X", known.name, known.did))
        }
        profile = updated
        statusLine = "DID ifyllda: " + lines.joined(separator: " · ")
    }

    /// One tap: find DIDs that decode to plausible values, then find implemented routines.
    func autoConfigure() async {
        await autoFindValues(from: autoSettings.didStart, count: autoSettings.didCount)
        await autoFindRoutines(from: autoSettings.ridStart, count: autoSettings.ridCount)
    }

    /// Reads every DID in the range and keeps the ones that decode to something physical.
    /// The scaling table is in AutoConfig.swift; the ranges are a search shortcut, since
    /// the real map lives in the ODX pack and not in this app.
    func autoFindValues(from start: UInt16, count: Int) async {
        await run("letar värden") {
            self.discoveredDIDs.removeAll()
            var found: [ValueCandidate] = []
            for i in 0..<count {
                let did = start &+ UInt16(i)
                self.autoProgress = String(format: "%04X  (%d/%d)", did, i + 1, count)
                if let data = try? await self.ecu.readDID(did), !data.isEmpty {
                    self.discoveredDIDs.append(String(format: "%04X: %@", did, data.hex))
                    if self.discoveredDIDs.count > 300 {
                        self.discoveredDIDs.removeFirst(self.discoveredDIDs.count - 300)
                    }
                    found.append(contentsOf: ValueProbe.candidates(did: did, data: data))
                }
                if i % 8 == 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
            }
            self.autoProgress = ""
            self.apply(ValueProbe.bestPerDID(found))
        }
    }

    /// `31 03` only — never `31 01`. Asking for results is read-only, so this cannot
    /// start anything in the car. Every RID that answers becomes a row in the routine list.
    func autoFindRoutines(from start: UInt16, count: Int) async {
        await run("letar rutiner") {
            self.discoveredRoutines.removeAll()
            var newActions: [RoutineAction] = []
            for i in 0..<count {
                let rid = start &+ UInt16(i)
                self.autoProgress = String(format: "%04X  (%d/%d)", rid, i + 1, count)
                if let response = try? await self.ecu.routineResults(rid), !response.isEmpty {
                    self.discoveredRoutines.append(String(format: "%04X: %@", rid, response.hex))
                    if self.discoveredRoutines.count > 300 {
                        self.discoveredRoutines.removeFirst(self.discoveredRoutines.count - 300)
                    }
                    let known = self.profile.actions.contains { $0.rid == rid }
                        || newActions.contains { $0.rid == rid }
                    if !known, newActions.count < 40 {
                        newActions.append(RoutineAction(name: String(format: "RID %04X", rid),
                                                        rid: rid,
                                                        parameters: [],
                                                        role: nil))
                    }
                }
                if i % 8 == 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
            }
            self.autoProgress = ""
            if !newActions.isEmpty {
                self.profile.actions.append(contentsOf: newActions)
            }
            self.statusLine = newActions.isEmpty
                ? "Hittade \(self.discoveredRoutines.count) rutiner, inga nya att mappa"
                : "Hittade \(self.discoveredRoutines.count) rutiner, la till \(newActions.count) i mappningen"
        }
    }

    /// Fills empty channels with the best candidates and reports what it did.
    private func apply(_ candidates: [ValueCandidate]) {
        guard !candidates.isEmpty else {
            statusLine = "Hittade inga värden i intervallet"
            return
        }

        var updated = profile
        var used: Set<UInt16> = []
        var lines: [String] = []
        let overwrite = autoSettings.overwriteExisting

        func take(_ kind: ValueKind) -> ValueCandidate? {
            let match = candidates
                .filter { $0.kind == kind && !used.contains($0.did) }
                .max { ValueProbe.confidence($0) < ValueProbe.confidence($1) }
            if let match { used.insert(match.did) }
            return match
        }

        let batteryID = updated.battery
        if let battery = take(.voltage),
           let index = updated.channels.firstIndex(where: { $0.id == batteryID }) {
            updated.channels[index].did = battery.did
            updated.channels[index].length = battery.length
            updated.channels[index].scale = battery.scale
            updated.channels[index].signed = battery.signed
            updated.channels[index].offset = 0
            lines.append(String(format: "batteri %04X = %.1f V", battery.did, battery.value))
        }

        if let pressure = take(.pressure),
           let index = updated.channels.firstIndex(where: {
               ($0.unit ?? "").lowercased() == "bar" && (overwrite || $0.did == 0)
           }) {
            updated.channels[index].did = pressure.did
            updated.channels[index].length = pressure.length
            updated.channels[index].scale = pressure.scale
            updated.channels[index].signed = pressure.signed
            updated.channels[index].offset = 0
            lines.append(String(format: "tryck %04X = %.2f bar", pressure.did, pressure.value))
        }

        if let temperature = take(.temperature),
           let index = updated.channels.firstIndex(where: {
               ($0.unit ?? "").uppercased().contains("C") && (overwrite || $0.did == 0)
           }) {
            updated.channels[index].did = temperature.did
            updated.channels[index].length = temperature.length
            updated.channels[index].scale = temperature.scale
            updated.channels[index].signed = temperature.signed
            updated.channels[index].offset = 0
            lines.append(String(format: "temp %04X = %.0f °C", temperature.did, temperature.value))
        }

        let heights = candidates
            .filter { $0.kind == .distance && !used.contains($0.did)
                && $0.value >= 280 && $0.value <= 480 }
            .sorted { $0.did < $1.did }

        var slot = 0
        for candidate in heights {
            while slot < 4, slot < updated.channels.count,
                  !overwrite, updated.channels[slot].did != 0 {
                slot += 1
            }
            guard slot < 4, slot < updated.channels.count else { break }
            updated.channels[slot].did = candidate.did
            updated.channels[slot].length = candidate.length
            updated.channels[slot].scale = candidate.scale
            updated.channels[slot].signed = candidate.signed
            updated.channels[slot].offset = 0
            let title = WheelSlot(rawValue: slot)?.title ?? "Kanal \(slot + 1)"
            lines.append(String(format: "%@ %04X = %.0f mm", title, candidate.did, candidate.value))
            slot += 1
        }

        guard !lines.isEmpty else {
            statusLine = "Hittade \(candidates.count) tolkningar men ingen tom kanal att fylla"
            return
        }
        profile = updated
        rebuildReadings()
        statusLine = "Auto: " + lines.joined(separator: " · ")
    }

    // MARK: Identify

    /// Reads the four wheel channels. Nil where a channel has no DID or does not answer.
    private func heightSnapshot() async -> [Double?] {
        var out: [Double?] = []
        for channel in profile.channels.prefix(4) {
            guard channel.did != 0,
                  let data = try? await ecu.readDID(channel.did) else {
                out.append(nil)
                continue
            }
            out.append(channel.decode(data))
        }
        return out
    }

    /// Runs one routine for a few seconds and measures how the corners moved.
    /// If the movement matches the selected role's direction, the role is assigned.
    func identify(_ action: RoutineAction, role: ActionRole?) async {
        guard action.rid != 0 else {
            statusLine = "\(action.name): RID saknas"
            return
        }
        guard profile.channels.prefix(4).allSatisfy({ $0.did != 0 }) else {
            statusLine = "Identifiering kräver fyra höjd-DID — kör Autokonfigurering först"
            return
        }

        await run("identifierar \(action.name)") {
            let before = await self.heightSnapshot()

            self.stopRequested = false
            self.canStop = true
            defer { self.canStop = false }
            _ = try? await self.ecu.runRoutine(action.rid,
                                               parameters: action.parameters,
                                               maxSeconds: 8,
                                               shouldStop: { self.stopRequested })
            _ = try? await self.ecu.stopRoutine(action.rid)
            try? await Task.sleep(nanoseconds: 800_000_000)

            let after = await self.heightSnapshot()
            var deltas: [(WheelSlot, Double)] = []
            for (index, slot) in WheelSlot.allCases.enumerated() {
                guard index < before.count, index < after.count,
                      let old = before[index], let new = after[index] else { continue }
                deltas.append((slot, new - old))
            }

            let front = deltas.filter { $0.0.axle == .front }.map { $0.1 }
            let rear = deltas.filter { $0.0.axle == .rear }.map { $0.1 }
            let frontMean = front.isEmpty ? nil : front.reduce(0, +) / Double(front.count)
            let rearMean = rear.isEmpty ? nil : rear.reduce(0, +) / Double(rear.count)

            let summary = deltas
                .map { String(format: "%@ %+.0f mm", $0.0.title, $0.1) }
                .joined(separator: " · ")

            if let role, self.matches(role: role, front: frontMean, rear: rearMean) {
                self.assign(role, to: action.id)
                self.statusLine = "\(role.title) → \(action.name). \(summary)"
            } else if summary.isEmpty {
                self.statusLine = "\(action.name): inga höjder avlästa"
            } else {
                self.statusLine = "\(action.name): \(summary)"
            }
        }
    }

    /// Did the axle move at least 5 mm in the direction the role implies?
    private func matches(role: ActionRole, front: Double?, rear: Double?) -> Bool {
        func moved(_ value: Double?, _ sign: Double) -> Bool { (value ?? 0) * sign >= 5 }
        switch role {
        case .raiseFront: return moved(front, 1)
        case .lowerFront, .ventFront: return moved(front, -1)
        case .raiseRear: return moved(rear, 1)
        case .lowerRear, .ventRear: return moved(rear, -1)
        default: return false
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

    var batteryChannel: HeightChannel? {
        if let id = profile.battery,
           let channel = profile.channels.first(where: { $0.id == id }) { return channel }
        return profile.channels.first { ($0.unit ?? "").uppercased() == "V" }
    }

    var batteryReading: HeightReading? {
        guard let id = profile.battery,
              let index = profile.channels.firstIndex(where: { $0.id == id }),
              index < readings.count else { return nil }
        return readings[index]
    }

    /// Everything after the fourth channel except the battery, which has its own card.
    var systemChannels: [HeightChannel] {
        let batteryID = batteryChannel?.id
        return profile.channels.dropFirst(4).filter { $0.id != batteryID }
    }

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
        lastAction = action
        stopRequested = false
        canStop = true
        defer { canStop = false }
        return await run(action.name) {
            let result = try await self.ecu.runRoutine(action.rid,
                                                       parameters: action.parameters,
                                                       shouldStop: { self.stopRequested }) { msg in
                self.statusLine = "\(action.name): \(msg)"
            }
            self.statusLine = "\(action.name): klar \(result.hex)"
        }
    }

    /// Asks a running routine to stop. The next 31 03 poll is replaced by 31 02.
    func requestStop() {
        guard canStop else { return }
        stopRequested = true
        statusLine = "Stoppar …"
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
        await autoFindRoutines(from: start, count: count)
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
        } catch is CancellationError {
            statusLine = "\(label): stoppad"
            return false
        } catch {
            statusLine = "\(label): \(error.localizedDescription)"
            return false
        }
    }
}
