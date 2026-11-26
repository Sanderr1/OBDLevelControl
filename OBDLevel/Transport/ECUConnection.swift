import Foundation

/// UDS (ISO 14229) over the OBDeleven adapter.
final class ECUConnection {

    let transport: OBDelevenTransport

    /// Module 34 (air suspension) on the C7 platform is `LL_RideContrSysteUDS`:
    /// request `0x755`, response `0x7BF`. `0x714/0x77E` is the instrument cluster
    /// (`LL_DashBoardUDS`) and `0x710/0x77A` is the gateway; both answer `22 F1 87`
    /// but reject every air-suspension DID with NRC 0x31.
    var txId: UInt32 = 0x755
    var rxId: UInt32 = 0x7BF

    /// 0x03 = extended session, 0x02 = programming, 0x01 = default
    var sessionType: UInt8 = 0x03

    init(transport: OBDelevenTransport) {
        self.transport = transport
    }

    // MARK: Setup

    struct OpenReport {
        var steps: [String]
        /// True when the ECU answered at all. This does **not** prove the pair is
        /// module 34: the cluster and gateway answer `10 03`/`3E 00` too.
        var answered: Bool
        var summary: String { steps.joined(separator: " · ") }
    }

    /// Sends the ladder that has to work before anything else can: protocol, CAN ids,
    /// extended session, tester present. Each step is reported instead of swallowed,
    /// because "connected" at BLE level says nothing about the car answering.
    @discardableResult
    func open(proto: DeviceProtocol = .isoTP, idWidth: Int = 4) async throws -> OpenReport {
        var steps: [String] = []
        try await transport.setProtocol(proto)
        steps.append("20 02 ok")

        try await transport.setCAN(tx: txId, rx: rxId, width: idWidth)
        steps.append(String(format: "CAN %03X→%03X ok", txId, rxId))

        var answered = false
        do {
            let session = try await send([0x10, sessionType])
            answered = true
            steps.append("10 03 → " + session.hex)
        } catch {
            steps.append("10 03 → " + Self.short(error))
        }
        do {
            let alive = try await send([0x3E, 0x00])
            answered = true
            steps.append("3E 00 → " + alive.hex)
        } catch {
            steps.append("3E 00 → " + Self.short(error))
        }

        transport.note("ECU open tx=\(String(format: "%03X", txId)) rx=\(String(format: "%03X", rxId))"
                       + (answered ? " answers" : " silent")
                       + " (identitet kontrolleras separat)")
        return OpenReport(steps: steps, answered: answered)
    }

    // MARK: Identity

    struct ModuleIdentity {
        var ok = false
        /// The module-34-specific DIDs that answered, e.g. "258F · 2B83".
        var proof = ""
        var steps: [String] = []
        var summary: String { steps.joined(separator: " · ") }
    }

    /// Proves that `755/7BF` really is module 34. `22 F1 87` is read for context,
    /// but it is not proof: the gateway and the instrument cluster answer it too.
    /// Only a positive answer to a DID from the air-suspension ODX counts.
    ///
    /// `fast` stops at the first proof DID. The CAN probe uses it to spend its
    /// time on the pair, not on producing a complete identity report.
    func identifyModule34(fast: Bool = false, timeout: TimeInterval = 2) async -> ModuleIdentity {
        var report = ModuleIdentity()

        do {
            let data = try await readDID(0xF187, timeout: timeout)
            report.steps.append("F187 = " + Self.text(data))
        } catch {
            report.steps.append("F187 → " + Self.short(error))
        }

        var proof: [String] = []
        for did in [UInt16(0x258F), 0x2B83, 0x2B92] {
            do {
                let data = try await readDID(did, timeout: timeout)
                report.ok = true
                proof.append(String(format: "%04X", did))
                report.steps.append(String(format: "%04X = %@", did, data.hex))
                if fast { break }
            } catch {
                report.steps.append(String(format: "%04X → %@", did, Self.short(error)))
            }
        }
        report.proof = proof.joined(separator: " · ")

        transport.note("modul 34 identitet: " + (report.ok ? "JA" : "NEJ")
                       + " · " + report.summary)
        return report
    }

    /// F187 is usually ASCII (part number, VIN or similar). Non-printable bytes
    /// become `·` so a binary identity value is still readable in the log.
    static func text(_ bytes: [UInt8]) -> String {
        let chars = bytes.map { byte -> Character in
            if byte >= 0x20 && byte <= 0x7E { return Character(UnicodeScalar(byte)) }
            return "·"
        }
        let value = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? bytes.hex : value
    }

    static func short(_ error: Error) -> String {
        if let obd = error as? OBDError { return obd.errorDescription ?? "fel" }
        return error.localizedDescription
    }

    // MARK: Core

    @discardableResult
    func send(_ payload: [UInt8], retries: Int = 3, timeout: TimeInterval = 5) async throws -> [UInt8] {
        let started = Date()
        let what = Self.describe(payload)
        var attempt = 0

        while true {
            let outcome: Result<[UInt8], Error>
            do { outcome = .success(try await transport.uds(payload, timeout: timeout)) }
            catch { outcome = .failure(error) }

            switch outcome {
            case .failure(let error):
                log(payload, what, response: nil, error: error, started: started)
                throw error

            case .success(let response):
                if response.count >= 3, response[0] == 0x7F,
                   response[2] == 0x21 || response[2] == 0x23,
                   attempt < retries {
                    attempt += 1
                    let nrc = response[2]
                    log(payload, what, response: response, error: nil, started: started,
                        extra: String(format: "NRC 0x%02X %@, retry %d/%d",
                                      nrc, NRC.text(nrc), attempt, retries))
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }

                log(payload, what, response: response, error: nil, started: started)

                if response.count >= 3, response[0] == 0x7F {
                    throw OBDError.nrc(response[2])
                }
                // `21 00` is the adapter saying "request sent, nothing came back".
                // Treating it as a successful empty answer made the ECU look open.
                if response.isEmpty { throw OBDError.badResponse("tomt svar (inget från modulen)") }
                return response
            }
        }
    }

    /// One line per logical request with everything needed to debug it later:
    /// direction pair, service, decoded DID/RID, raw bytes, NRC name and elapsed
    /// time. Retries are logged as their own line.
    private func log(_ payload: [UInt8], _ what: String, response: [UInt8]?,
                     error: Error?, started: Date, extra: String? = nil) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        var line = String(format: "%03X→%03X  %@  %@  → ", txId, rxId, payload.hex, what)
        if let response, !response.isEmpty {
            line += response.hex
        } else if error == nil {
            line += "tomt svar"
        } else {
            line += "—"
        }
        if let error {
            if let obd = error as? OBDError, case .nrc(let code) = obd {
                line += String(format: "  · NRC 0x%02X %@", code, NRC.text(code))
            } else {
                line += "  · " + Self.short(error)
            }
        }
        if let extra { line += "  · " + extra }
        line += "  · \(ms) ms"
        transport.note(line)
    }

    static func describe(_ payload: [UInt8]) -> String {
        guard let service = payload.first else { return "tom" }
        switch service {
        case 0x10:
            guard payload.count >= 2 else { return "DiagnosticSessionControl" }
            return String(format: "DiagnosticSessionControl session %02X", payload[1])
        case 0x11: return "ECUReset"
        case 0x14: return "ClearDiagnosticInformation"
        case 0x19: return "ReadDTCInformation"
        case 0x22:
            guard payload.count >= 3 else { return "ReadDataByIdentifier" }
            return String(format: "ReadDataByIdentifier DID %02X%02X", payload[1], payload[2])
        case 0x27:
            guard payload.count >= 2 else { return "SecurityAccess" }
            return String(format: "SecurityAccess level %02X", payload[1])
        case 0x28: return "CommunicationControl"
        case 0x2E:
            guard payload.count >= 3 else { return "WriteDataByIdentifier" }
            return String(format: "WriteDataByIdentifier DID %02X%02X", payload[1], payload[2])
        case 0x2F:
            guard payload.count >= 4 else { return "InputOutputControlByIdentifier" }
            return String(format: "InputOutputControlByIdentifier DID %02X%02X control %02X",
                          payload[1], payload[2], payload[3])
        case 0x31:
            guard payload.count >= 4 else { return "RoutineControl" }
            let sub: String
            switch payload[1] {
            case 0x01: sub = "start"
            case 0x02: sub = "stop"
            case 0x03: sub = "results"
            default: sub = String(format: "sub %02X", payload[1])
            }
            return String(format: "RoutineControl %@ RID %02X%02X", sub, payload[2], payload[3])
        case 0x3E: return "TesterPresent"
        case 0x85: return "ControlDTCSetting"
        default: return String(format: "service %02X", service)
        }
    }

    func testerPresent() async {
        _ = try? await send([0x3E, 0x00])
    }

    // MARK: Data

    func readDID(_ did: UInt16, timeout: TimeInterval = 5) async throws -> [UInt8] {
        let response = try await send([0x22, UInt8(did >> 8), UInt8(did & 0xFF)], timeout: timeout)
        guard response.count >= 3, response[0] == 0x62 else {
            throw OBDError.badResponse(response.hex)
        }
        // A positive answer must echo the DID that was asked for. Without this
        // check a stray `62` from another request looks like a valid value.
        let echoed = UInt16(response[1]) << 8 | UInt16(response[2])
        guard echoed == did else {
            throw OBDError.badResponse(String(format: "DID-eko %04X ≠ %04X: %@",
                                              echoed, did, response.hex))
        }
        return Array(response[3...])
    }

    // MARK: Routines

    func startRoutine(_ rid: UInt16, parameters: [UInt8] = []) async throws -> [UInt8] {
        try await send([0x31, 0x01, UInt8(rid >> 8), UInt8(rid & 0xFF)] + parameters)
    }

    func stopRoutine(_ rid: UInt16, parameters: [UInt8] = []) async throws -> [UInt8] {
        try await send([0x31, 0x02, UInt8(rid >> 8), UInt8(rid & 0xFF)] + parameters)
    }

    func routineResults(_ rid: UInt16) async throws -> [UInt8] {
        try await send([0x31, 0x03, UInt8(rid >> 8), UInt8(rid & 0xFF)])
    }

    /// Starts a routine and polls 31 03 until the ECU stops reporting "running".
    /// Returns the last results payload (everything after `71 01 ridHi ridLo`).
    func runRoutine(_ rid: UInt16,
                    parameters: [UInt8] = [],
                    pollInterval: TimeInterval = 0.4,
                    maxSeconds: Double = 90,
                    shouldStop: (() -> Bool)? = nil,
                    progress: ((String) -> Void)? = nil) async throws -> [UInt8] {

        let started = try await startRoutine(rid, parameters: parameters)
        guard started.first == 0x71 else { throw OBDError.badResponse(started.hex) }
        progress?("routine started")

        let deadline = Date().addingTimeInterval(maxSeconds)
        var last: [UInt8] = []

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))

            if shouldStop?() == true {
                _ = try? await stopRoutine(rid)
                progress?("stopped")
                throw CancellationError()
            }
            do {
                last = try await routineResults(rid)
            } catch OBDError.nrc(let code) where code == 0x23 || code == 0x21 {
                progress?("still running")
                continue
            }
            progress?("results " + last.hex)

            // `71 03 <ridHi> <ridLo> <status> <payload…>`. The status byte is the
            // fifth byte, not the fourth: the fourth is the low byte of the RID.
            guard last.count >= 4, last[0] == 0x71 else {
                throw OBDError.badResponse(last.hex)
            }
            if last.count < 5 { return last }
            let status = last[4]
            // 0x00 not active, 0x01 running, 0x02 finished ok, 0x03 finished with error
            if status != 0x01 { return last }
        }
        _ = try? await stopRoutine(rid)
        throw OBDError.timeout
    }

    // MARK: Output tests

    /// `2F <DID> <control> <data>` — InputOutputControlByIdentifier. The official
    /// client sends control `03` (short-term adjustment) with the option record,
    /// and `00` (return control to the ECU) to stop.
    @discardableResult
    func outputTest(_ did: UInt16,
                    control: UInt8 = 0x03,
                    data: [UInt8] = [],
                    timeout: TimeInterval = 5) async throws -> [UInt8] {
        let response = try await send([0x2F, UInt8(did >> 8), UInt8(did & 0xFF), control] + data,
                                      timeout: timeout)
        guard response.first == 0x6F else {
            throw OBDError.badResponse(response.hex)
        }
        return response
    }

    @discardableResult
    func stopOutputTest(_ did: UInt16) async throws -> [UInt8] {
        try await outputTest(did, control: 0x00)
    }

    // MARK: Security access

    /// 27 01 seed -> caller-supplied key -> 27 02 key
    func securityAccess(level: UInt8 = 0x01,
                        keyAlgorithm: (([UInt8]) -> [UInt8])?) async throws {
        let seedResponse = try await send([0x27, level])
        guard seedResponse.count >= 2, seedResponse[0] == 0x67 else {
            throw OBDError.badResponse(seedResponse.hex)
        }
        let seed = Array(seedResponse.dropFirst(2))
        transport.note("seed " + seed.hex)

        guard let algorithm = keyAlgorithm else { throw OBDError.securityKeyMissing }
        let key = algorithm(seed)
        let keyResponse = try await send([0x27, level + 1] + key)
        guard keyResponse.count >= 2, keyResponse[0] == 0x67 else {
            throw OBDError.badResponse(keyResponse.hex)
        }
        transport.note("security access granted")
    }
}
