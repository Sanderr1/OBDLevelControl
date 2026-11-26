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
    case raiseHigh
    case lowerNormal
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
        case .raiseHigh: return "Höj till högläge"
        case .lowerNormal: return "Sänk till normalnivå"
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

/// A measuring value that the EV_AirSuspe unit (Audi A6 C7 air suspension) lists.
/// The numbers are DIDs from the module's own live-data list and do not change;
/// only the labels come from the ODX pack.
struct KnownDID {
    let name: String
    let did: UInt16
    let length: Int
    let scale: Double
    let unit: String?
    var signed: Bool = false
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
    /// Bytes per CAN id in the adapter's 0x22 ioctl. Nil means the usual four.
    var idWidth: Int?

    /// Live data as the module lists it. Heights first on purpose: the overview reads
    /// the first four channels and calls them the wheels.
    static let knownDIDs: [KnownDID] = [
        KnownDID(name: "Vänster fram", did: 0x258F, length: 2, scale: 0.1, unit: "mm"),
        KnownDID(name: "Höger fram", did: 0x2590, length: 2, scale: 0.1, unit: "mm"),
        KnownDID(name: "Vänster bak", did: 0x2591, length: 2, scale: 0.1, unit: "mm"),
        KnownDID(name: "Höger bak", did: 0x2592, length: 2, scale: 0.1, unit: "mm"),

        KnownDID(name: "Systemtryck", did: 0x2B83, length: 2, scale: 0.01, unit: "bar"),
        KnownDID(name: "Kompressortemperatur", did: 0x2B84, length: 1, scale: 1, unit: "°C"),
        KnownDID(name: "Beräknad kompressortemp", did: 0x2B96, length: 2, scale: 0.1, unit: "°C"),
        KnownDID(name: "Kompressor omgivningstemp", did: 0x2B97, length: 2, scale: 0.1, unit: "°C"),

        KnownDID(name: "Absolut höjd VF", did: 0x2B8E, length: 2, scale: 0.1, unit: "mm"),
        KnownDID(name: "Absolut höjd HF", did: 0x2B8F, length: 2, scale: 0.1, unit: "mm"),
        KnownDID(name: "Absolut höjd VB", did: 0x2B90, length: 2, scale: 0.1, unit: "mm"),
        KnownDID(name: "Absolut höjd HB", did: 0x2B91, length: 2, scale: 0.1, unit: "mm"),

        KnownDID(name: "Avvikelse VF", did: 0x2B8A, length: 2, scale: 0.1, unit: "mm", signed: true),
        KnownDID(name: "Avvikelse HF", did: 0x2B8B, length: 2, scale: 0.1, unit: "mm", signed: true),
        KnownDID(name: "Avvikelse VB", did: 0x2B8C, length: 2, scale: 0.1, unit: "mm", signed: true),
        KnownDID(name: "Avvikelse HB", did: 0x2B8D, length: 2, scale: 0.1, unit: "mm", signed: true),

        KnownDID(name: "Nivåtryck VF", did: 0x1230, length: 2, scale: 0.1, unit: "hPa"),
        KnownDID(name: "Nivåtryck HF", did: 0x1232, length: 2, scale: 0.1, unit: "hPa"),
        KnownDID(name: "Nivåtryck VB", did: 0x1234, length: 2, scale: 0.1, unit: "hPa"),
        KnownDID(name: "Nivåtryck HB", did: 0x1236, length: 2, scale: 0.1, unit: "hPa"),

        KnownDID(name: "Systemstatus", did: 0x2B92, length: 2, scale: 1, unit: nil),
        KnownDID(name: "Nivåregulator villkor", did: 0x2B93, length: 2, scale: 1, unit: nil),
        KnownDID(name: "Börvärde nivå", did: 0x2B94, length: 2, scale: 0.1, unit: "mm"),

        KnownDID(name: "Börvärdeavvikelse VF", did: 0x2B98, length: 2, scale: 0.1, unit: "mm", signed: true),
        KnownDID(name: "Börvärdeavvikelse HF", did: 0x2B99, length: 2, scale: 0.1, unit: "mm", signed: true),
        KnownDID(name: "Börvärdeavvikelse VB", did: 0x2B9A, length: 2, scale: 0.1, unit: "mm", signed: true),
        KnownDID(name: "Börvärdeavvikelse HB", did: 0x2B9B, length: 2, scale: 0.1, unit: "mm", signed: true),

        KnownDID(name: "Audi drive select", did: 0x282A, length: 1, scale: 1, unit: nil),
        KnownDID(name: "Dörrar & luckor", did: 0x220D, length: 1, scale: 1, unit: nil),
        KnownDID(name: "Bilhissläge", did: 0x1309, length: 1, scale: 1, unit: nil)
    ]

    /// Every routine in module 34 is a basic setting. The last three bytes are the
    /// option record from the ODX table row (`DOP_TEXTTABLEVWCommoRoutiEntryOptioBasicSetti`
    /// codes `040000` as "Default Parameter Value").
    static let optionRecord: [UInt8] = [0x04, 0x00, 0x00]

    /// RID:s from `TAB_RoutiContrBasicSetti` in EV_AirSuspe_003024.odx, not guessed:
    /// `0x03DD` goes to high level, `0x03E0` to normal level, and the rest charge or
    /// bleed one axle. The two level routines already move both axles.
    static let knownActions: [(role: ActionRole, name: String, rid: UInt16)] = [
        (.raiseHigh, "Höj till högläge", 0x03DD),
        (.lowerNormal, "Sänk till normalnivå", 0x03E0),
        (.raiseFront, "Höj fram", 0x03CE),
        (.lowerFront, "Sänk fram", 0x03CB),
        (.raiseRear, "Höj bak", 0x03CF),
        (.lowerRear, "Sänk bak", 0x03CC),
        (.ventFront, "Vent fram", 0x03CB),
        (.ventRear, "Vent bak", 0x03CC),
        (.levelOff, "Nivåreglering av", 0x03D4),
        (.levelOn, "Nivåreglering på", 0x03C8),
        (.reservoirFill, "Fyll behållare", 0x03CD),
        (.reservoirVent, "Lufta behållare", 0x03CA)
    ]

    static var blank: LevelProfile {
        let battery = HeightChannel(name: "Batterispänning", did: 0x0000, length: 2,
                                    scale: 0.001, offset: 0, signed: false, unit: "V")
        var channels = knownDIDs.map {
            HeightChannel(name: $0.name, did: $0.did, length: $0.length, scale: $0.scale,
                          offset: 0, signed: $0.signed, unit: $0.unit)
        }
        channels.append(battery)
        let actions = knownActions.map {
            RoutineAction(name: $0.name, rid: $0.rid,
                          parameters: optionRecord, role: $0.role)
        }
        return LevelProfile(
            name: "Min bil",
            vehicle: "Luftfjädring · UDS",
            txId: 0x755,
            rxId: 0x7BF,
            channels: channels,
            actions: actions,
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
    /// True once module 34 has actually answered a request, not just when BLE is up.
    @Published private(set) var ecuOpen = false
    /// Which module-34-specific DIDs answered, e.g. "258F · 2B83 · 2B92".
    @Published private(set) var identityProof = ""
    /// Full identity probe result, shown in Diagnostik and copied with the log.
    @Published private(set) var identityLine = ""
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
        persist()
        readings = profile.channels.map {
            HeightReading(name: $0.name, did: $0.did, value: nil, raw: "–")
        }
    }

    /// Older profiles stored channels without units, routines without roles and had no
    /// battery channel. Roles used to be implied by the routine name, so bake that in once.
    private static func migrate(_ profile: inout LevelProfile) {
        // B20: module 34 is 755/7BF. Older probes could save the gateway 710/77A
        // (B18/B19) or the instrument cluster 714/77E (B19), and both answer
        // `10 03`/`22 F187` while rejecting every air-suspension DID with NRC 31.
        // Move only those known-wrong pairs; a custom pair the user typed is kept.
        let legacy: [(UInt32, UInt32)] = [
            (0x710, 0x77A), (0x77A, 0x710),
            (0x714, 0x77E), (0x77E, 0x714)
        ]
        if legacy.contains(where: { $0.0 == profile.txId && $0.1 == profile.rxId }) {
            profile.txId = 0x755
            profile.rxId = 0x7BF
            profile.idWidth = 4
        }

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

        applyKnownActions(&profile)

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

    /// Fills in the RID:s confirmed by the module ODX without touching anything the
    /// user has scanned or typed. A profile saved before B18 has the ten old roles
    /// but `rid: 0`; those rows get the real RID and the option record in place, and
    /// the two whole-car level routines are appended because they did not exist yet.
    private static func applyKnownActions(_ profile: inout LevelProfile) {
        for i in profile.actions.indices {
            let role = profile.actions[i].role
            guard profile.actions[i].rid == 0,
                  let known = LevelProfile.knownActions.first(where: { $0.role == role }) else { continue }
            profile.actions[i].rid = known.rid
            if profile.actions[i].parameters.isEmpty {
                profile.actions[i].parameters = LevelProfile.optionRecord
            }
        }
        for known in LevelProfile.knownActions where known.role == .raiseHigh || known.role == .lowerNormal {
            guard !profile.actions.contains(where: { $0.role == known.role }) else { continue }
            profile.actions.append(RoutineAction(name: known.name, rid: known.rid,
                                                 parameters: LevelProfile.optionRecord, role: known.role))
        }
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

    /// Opens the control unit and reports every step. Runs automatically when the
    /// adapter link comes up, so a BLE connection alone never looks like success.
    func connectECU() async {
        guard transport.ready else {
            statusLine = "Ingen adapter ansluten"
            ecuOpen = false
            return
        }
        ecuOpen = false
        identityProof = ""
        identityLine = ""
        let width = profile.idWidth ?? 4
        let ok = await run("kopplar upp") {
            self.ecu.txId = self.profile.txId
            self.ecu.rxId = self.profile.rxId
            let report = try await self.ecu.open(idWidth: width)
            self.transport.note("open: " + report.summary)
            let identity = await self.ecu.identifyModule34()
            self.ecuOpen = identity.ok
            self.identityProof = identity.proof
            self.identityLine = identity.summary
            if identity.ok {
                self.statusLine = "Modul 34 öppen · " + identity.proof
            } else {
                self.statusLine = String(format: "Fel ECU? Ingen modul-34-DID svarar på %03X→%03X",
                                         self.profile.txId, self.profile.rxId)
            }
        }
        guard ok, ecuOpen else { return }
        if autoSettings.onConnect {
            applyKnownDIDs(announce: false)
            await readHeights()
        }
    }

    /// True while any channel still lacks a DID or any routine lacks a RID.
    /// Used to avoid re-scanning an already configured car on every connect.
    var needsAutoConfig: Bool {
        profile.channels.contains { $0.did == 0 } || profile.actions.contains { $0.rid == 0 }
    }

    /// Called when the BLE link drops, so the header stops claiming the car answers.
    func handleDisconnect() {
        ecuOpen = false
        identityProof = ""
        identityLine = ""
        statusLine = "Adaptern frånkopplad"
    }

    // MARK: Self test

    /// Sweeps framing × write type against `08` and remembers the combination that
    /// answers, so the next connect starts there instead of timing out first.
    func probeLink() async {
        await run("prova länklägen") {
            let text = await self.transport.probeLink()
            self.statusLine = text
        }
    }

    /// Runs the whole ladder and reports where it stops. The first three steps talk
    /// to the adapter itself and need no car, so they prove whether the wire works
    /// at all; the rest needs the right CAN ids.
    func runSelfTest() async {
        await run("självtest") {
            var lines: [String] = []

            for code in [UInt8(0x08), 0x10, 0x12] {
                do {
                    let answer = try await self.transport.deviceQuery(code)
                    lines.append(String(format: "%02X → %@", code, answer.hex))
                    if code == 0x08, let gen = answer.first { self.transport.setGeneration(gen) }
                } catch {
                    lines.append(String(format: "%02X → %@", code, ECUConnection.short(error)))
                }
            }

            do {
                try await self.transport.setProtocol(.isoTP)
                lines.append("20 02 ok")
            } catch {
                lines.append("20 02 → " + ECUConnection.short(error))
            }

            do {
                try await self.transport.setCAN(tx: self.profile.txId,
                                                rx: self.profile.rxId,
                                                width: self.profile.idWidth ?? 4)
                lines.append(String(format: "CAN %03X→%03X ok", self.profile.txId, self.profile.rxId))
            } catch {
                lines.append("CAN → " + ECUConnection.short(error))
            }
            self.ecu.txId = self.profile.txId
            self.ecu.rxId = self.profile.rxId

            // Same order as the Android client: open the session first, then read.
            do {
                let session = try await self.ecu.send([0x10, 0x03])
                lines.append("10 03 → " + session.hex)
            } catch {
                lines.append("10 03 → " + ECUConnection.short(error))
            }

            let identity = await self.ecu.identifyModule34()
            self.ecuOpen = identity.ok
            self.identityProof = identity.proof
            self.identityLine = identity.summary
            lines.append(identity.summary)

            do {
                let alive = try await self.ecu.send([0x3E, 0x00])
                lines.append("3E 00 → " + alive.hex)
            } catch {
                lines.append("3E 00 → " + ECUConnection.short(error))
            }
            if identity.ok, let first = self.profile.channels.first(where: { $0.did != 0 }) {
                do {
                    let data = try await self.ecu.readDID(first.did)
                    lines.append(String(format: "22 %04X → %@", first.did, data.hex))
                } catch {
                    lines.append(String(format: "22 %04X → %@", first.did, ECUConnection.short(error)))
                }
            }
            self.statusLine = lines.joined(separator: " · ")
        }
    }

    // MARK: CAN id probe

    /// Tries the only pair module 34 can use: request `755`, response `7BF`, in
    /// both byte widths and both directions. It deliberately does not try other
    /// control units. A candidate only wins when a module-34-specific DID
    /// (`258F`, `2B83` or `2B92`) answers — `10 03`, `3E 00` and `22 F187` are
    /// answered by the cluster and gateway as well, which is exactly how earlier
    /// builds ended up "connected" to the wrong ECU. Read-only: no `31 01`.
    func probeCANIDs() async {
        guard transport.ready else {
            statusLine = "Anslut adaptern först"
            return
        }
        let candidates: [(tx: UInt32, rx: UInt32, width: Int, label: String)] = [
            (0x755, 0x7BF, 4, "Modul 34"),
            (0x755, 0x7BF, 2, "Modul 34, 2 byte"),
            (0x7BF, 0x755, 4, "Modul 34 omvänd"),
            (0x7BF, 0x755, 2, "Modul 34 omvänd, 2 byte")
        ]
        await run("letar CAN-id") {
            var lines: [String] = []
            var winner: (tx: UInt32, rx: UInt32, width: Int)?
            var winnerIdentity: ECUConnection.ModuleIdentity?
            for candidate in candidates {
                let label = String(format: "%03X→%03X", candidate.tx, candidate.rx)
                do {
                    try await self.transport.setProtocol(.isoTP)
                    try await self.transport.setCAN(tx: candidate.tx, rx: candidate.rx,
                                                    width: candidate.width)
                    self.ecu.txId = candidate.tx
                    self.ecu.rxId = candidate.rx
                    // Open the extended session before probing DIDs. The answer is
                    // deliberately not used as proof: the cluster and gateway open
                    // `10 03` too. It only gives module 34 the session its live
                    // values may expect.
                    _ = try? await self.ecu.send([0x10, 0x03], retries: 0, timeout: 1.5)
                    let identity = await self.ecu.identifyModule34(fast: true, timeout: 1.5)
                    if identity.ok {
                        lines.append("\(label) ✓ \(identity.proof)")
                        winner = (candidate.tx, candidate.rx, candidate.width)
                        winnerIdentity = identity
                        break
                    } else {
                        lines.append("\(label) ✗ ingen modul-34-DID")
                    }
                } catch {
                    lines.append("\(label) ✗ " + ECUConnection.short(error))
                }
            }
            if let winner {
                self.profile.txId = winner.tx
                self.profile.rxId = winner.rx
                self.profile.idWidth = winner.width
                self.ecu.txId = winner.tx
                self.ecu.rxId = winner.rx
                self.identityProof = winnerIdentity?.proof ?? ""
                self.identityLine = winnerIdentity?.summary ?? ""
                self.ecuOpen = true
                // Leave the adapter on the winning pair and open the session.
                let report = try? await self.ecu.open(idWidth: winner.width)
                self.statusLine = "Hittade: " + lines.joined(separator: " · ")
                    + (report.map { " · " + $0.summary } ?? "")
            } else {
                self.ecuOpen = false
                self.identityProof = ""
                self.identityLine = ""
                self.statusLine = "Inget svar alls: " + lines.joined(separator: " · ")
            }
        }
    }

    // MARK: Automatic configuration

    /// Rebuilds the channel list from the module's own live-data ids, reusing the
    /// channels that already exist so ids, scales and saved values survive.
    func applyKnownDIDs(overwrite: Bool? = nil, announce: Bool = true) {
        let replace = overwrite ?? autoSettings.overwriteExisting
        var updated = profile
        var lines: [String] = []
        var used = Set<UUID>()
        var built: [HeightChannel] = []

        for known in LevelProfile.knownDIDs {
            if let index = updated.channels.firstIndex(where: {
                $0.did == known.did && !used.contains($0.id)
            }) {
                var channel = updated.channels[index]
                used.insert(channel.id)
                if replace {
                    channel.name = known.name
                    channel.length = known.length
                    channel.scale = known.scale
                    channel.offset = 0
                    channel.signed = known.signed
                    channel.unit = known.unit
                }
                built.append(channel)
            } else {
                built.append(HeightChannel(name: known.name, did: known.did,
                                           length: known.length, scale: known.scale,
                                           offset: 0, signed: known.signed, unit: known.unit))
            }
            lines.append(String(format: "%@ %04X", known.name, known.did))
        }

        // Keep anything the user added that is not in the known list, battery included.
        for channel in updated.channels where !used.contains(channel.id) {
            built.append(channel)
        }

        if let id = updated.battery, built.contains(where: { $0.id == id }) {
            // already kept
        } else if let existing = built.first(where: {
            ($0.unit ?? "").uppercased() == "V" || $0.name.lowercased().contains("batteri")
        }) {
            updated.battery = existing.id
        } else {
            let channel = HeightChannel(name: "Batterispänning", did: 0x0000, length: 2,
                                        scale: 0.001, offset: 0, signed: false, unit: "V")
            built.append(channel)
            updated.battery = channel.id
        }

        updated.channels = built
        profile = updated
        rebuildReadings()
        if announce {
            statusLine = "\(lines.count) DID ifyllda"
        }
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
                if let data = try? await self.ecu.readDID(did, timeout: 1.2), !data.isEmpty {
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
                  let data = try? await ecu.readDID(channel.did, timeout: 3) else {
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
        guard ecuOpen else {
            statusLine = "Modul 34 är inte verifierad – kör Testa anslutning först"
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
        case .raiseHigh: return moved(front, 1) && moved(rear, 1)
        case .lowerNormal: return moved(front, -1) && moved(rear, -1)
        case .raiseFront: return moved(front, 1)
        case .lowerFront, .ventFront: return moved(front, -1)
        case .raiseRear: return moved(rear, 1)
        case .lowerRear, .ventRear: return moved(rear, -1)
        default: return false
        }
    }

    // MARK: Heights

    /// The four wheels plus the battery: everything the overview and the battery card
    /// need on a 2 s refresh. Reading all 30 known ids every tick would take seconds.
    var fastChannels: [HeightChannel] {
        var list = wheelChannels
        if let battery = batteryChannel, !list.contains(where: { $0.id == battery.id }) {
            list.append(battery)
        }
        return list
    }

    func readHeights() async {
        await read(fastChannels, label: "läser höjder")
    }

    /// Reads every channel the profile has, including the system values.
    func readAllChannels() async {
        await read(profile.channels, label: "läser alla kanaler")
    }

    private func read(_ channels: [HeightChannel], label: String) async {
        await run(label) {
            let wanted = Set(channels.map(\.id))
            var out: [HeightReading] = []
            var summary: [String] = []
            var failures: [String] = []
            var detail: [String] = []
            for channel in self.profile.channels {
                let previous = self.readings.first { $0.did == channel.did && $0.name == channel.name }
                guard wanted.contains(channel.id) else {
                    out.append(previous ?? HeightReading(name: channel.name,
                                                         did: channel.did,
                                                         value: nil,
                                                         raw: channel.did == 0 ? "no DID" : "–"))
                    continue
                }
                guard channel.did != 0 else {
                    out.append(HeightReading(name: channel.name, did: 0, value: nil, raw: "no DID"))
                    continue
                }
                do {
                    let data = try await self.ecu.readDID(channel.did, timeout: 2)
                    let value = channel.decode(data)
                    out.append(HeightReading(name: channel.name,
                                             did: channel.did,
                                             value: value,
                                             raw: data.hex))
                    if let value {
                        summary.append(String(format: "%.1f", value))
                        detail.append(String(format: "%@ %04X=%.1f%@",
                                             channel.name, channel.did, value,
                                             channel.unit ?? ""))
                    } else {
                        detail.append(String(format: "%@ %04X=rå %@",
                                             channel.name, channel.did, data.hex))
                    }
                } catch {
                    let reason = ECUConnection.short(error)
                    out.append(HeightReading(name: channel.name,
                                             did: channel.did,
                                             value: nil,
                                             raw: "err " + reason))
                    failures.append(String(format: "%@ %04X: %@",
                                           channel.name, channel.did, reason))
                    detail.append(String(format: "%@ %04X=✗ %@",
                                         channel.name, channel.did, reason))
                }
            }
            self.readings = out
            self.ecuOpen = self.ecuOpen || out.contains(where: { $0.value != nil })
            if !detail.isEmpty {
                self.transport.note("\(label): " + detail.joined(separator: " · "))
            }
            if !failures.isEmpty {
                self.statusLine = "\(failures.count) fel: "
                    + failures.prefix(4).joined(separator: " · ")
                    + (failures.count > 4 ? " …" : "")
            } else {
                self.statusLine = summary.isEmpty ? "Inga värden" : summary.joined(separator: " / ")
            }
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
        // A routine writes to the car. Never send `31 01` before a
        // module-34-specific DID has proved that 755/7BF is the right ECU;
        // "10 03 answered" is also true for the cluster and gateway.
        guard ecuOpen else {
            statusLine = "Modul 34 är inte verifierad – kör Testa anslutning eller Hitta CAN-id först"
            return false
        }
        lastAction = action
        stopRequested = false
        canStop = true
        defer { canStop = false }
        let seconds = Self.maxDuration(for: action.role)
        return await run(action.name) {
            let result = try await self.ecu.runRoutine(action.rid,
                                                       parameters: action.parameters,
                                                       maxSeconds: seconds,
                                                       shouldStop: { self.stopRequested }) { msg in
                self.statusLine = "\(action.name): \(msg)"
            }
            self.statusLine = "\(action.name): klar \(result.hex)"
        }
    }

    /// A level move physically takes tens of seconds, while switching a function on
    /// or off is quick. The ceiling only exists so a silent ECU cannot hang the app;
    /// Stoppa still ends a move at once.
    private static func maxDuration(for role: ActionRole?) -> Double {
        guard let role else { return 25 }
        switch role {
        case .raiseHigh, .lowerNormal, .raiseFront, .lowerFront, .raiseRear, .lowerRear,
             .ventFront, .ventRear, .reservoirFill, .reservoirVent:
            return 75
        case .levelOff, .levelOn:
            return 25
        }
    }

    /// Moves both axles on one press. `0x03DD` and `0x03E0` are whole-car level
    /// routines, so normally one call is enough. Sänk leaves self-levelling off, so
    /// `0x03C8` switches it back on afterwards. A profile without those two rows
    /// falls back to the per-axle charge/bleed pair.
    func moveBoth(up: Bool) async {
        let role: ActionRole = up ? .raiseHigh : .lowerNormal
        if let routine = action(for: role), routine.rid != 0 {
            statusLine = up ? "Höjer till högläge…" : "Sänker till normalnivå…"
            guard await runAction(routine) else { return }
            if !up, let on = action(for: .levelOn), on.rid != 0 {
                statusLine = "Nivåreglering på…"
                guard await runAction(on) else { return }
            }
            statusLine = up ? "Höjt till högläge" : "Sänkt till normalnivå"
            return
        }

        let roles: [ActionRole] = up ? [.raiseFront, .raiseRear] : [.lowerFront, .lowerRear]
        let actions = roles.compactMap { action(for: $0) }.filter { $0.rid != 0 }
        guard actions.count == 2 else {
            statusLine = "\(up ? "Höj" : "Sänk") saknar mappad rutin (Inställningar → Funktionsmappning)"
            return
        }
        stopRequested = false
        var finished = 0
        for (index, action) in actions.enumerated() {
            if stopRequested { break }
            statusLine = "\(up ? "Höjer" : "Sänker") \(index == 0 ? "fram" : "bak")…"
            guard await runAction(action) else { break }
            finished += 1
            if index == 0 { try? await Task.sleep(nanoseconds: 600_000_000) }
        }
        if finished == 2 { statusLine = "\(up ? "Höjt" : "Sänkt") båda axlarna" }
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
            // Two bytes or fewer and one of the device opcodes: talk to the adapter
            // itself (08 generation, 10 version, 12 serial, 16 voltage).
            if bytes.count == 1, [0x08, 0x10, 0x12, 0x16].contains(bytes[0]) {
                let answer = try await self.transport.deviceQuery(bytes[0])
                self.statusLine = String(format: "enhet %02X → %@", bytes[0], answer.hex)
                self.transport.note(String(format: "device %02X -> %@", bytes[0], answer.hex))
                return
            }
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
                    let data = try await self.ecu.readDID(did, timeout: 1.5)
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
