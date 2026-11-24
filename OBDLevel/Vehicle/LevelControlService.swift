import Foundation

// MARK: - Models

struct HeightChannel: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var did: UInt16
    var length: Int
    var scale: Double
    var offset: Double
    var signed: Bool

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
}

struct LevelProfile: Codable {
    var name: String
    var txId: UInt32
    var rxId: UInt32
    var channels: [HeightChannel]
    var actions: [RoutineAction]

    static let blank = LevelProfile(
        name: "My car",
        txId: 0x714,
        rxId: 0x77E,
        channels: [
            HeightChannel(name: "Front left", did: 0x0000, length: 2, scale: 0.1, offset: 0, signed: true),
            HeightChannel(name: "Front right", did: 0x0000, length: 2, scale: 0.1, offset: 0, signed: true),
            HeightChannel(name: "Rear left", did: 0x0000, length: 2, scale: 0.1, offset: 0, signed: true),
            HeightChannel(name: "Rear right", did: 0x0000, length: 2, scale: 0.1, offset: 0, signed: true)
        ],
        actions: [
            RoutineAction(name: "Vent front axle", rid: 0x0000, parameters: []),
            RoutineAction(name: "Vent rear axle", rid: 0x0000, parameters: []),
            RoutineAction(name: "Level control off", rid: 0x0000, parameters: []),
            RoutineAction(name: "Level control on", rid: 0x0000, parameters: [])
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
        readings = profile.channels.map {
            HeightReading(name: $0.name, did: $0.did, value: nil, raw: "-")
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

    // MARK: Actions

    func runAction(_ action: RoutineAction) async {
        guard action.rid != 0 else {
            statusLine = "\(action.name): no routine id configured"
            return
        }
        await run(action.name) {
            let result = try await self.ecu.runRoutine(action.rid,
                                                       parameters: action.parameters) { msg in
                self.statusLine = "\(action.name): \(msg)"
            }
            self.statusLine = "\(action.name): done \(result.hex)"
        }
    }

    func stopAction(_ action: RoutineAction) async {
        guard action.rid != 0 else { return }
        await run("stopping") {
            _ = try await self.ecu.stopRoutine(action.rid)
            self.statusLine = "\(action.name): stopped"
        }
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

    private func run(_ label: String, _ body: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        statusLine = label
        defer { busy = false }
        do {
            try await body()
        } catch {
            statusLine = "\(label): \(error.localizedDescription)"
        }
    }
}
