import Foundation

/// UDS (ISO 14229) over the OBDeleven adapter.
final class ECUConnection {

    let transport: OBDelevenTransport

    var txId: UInt32 = 0x714
    var rxId: UInt32 = 0x77E

    /// 0x03 = extended session, 0x02 = programming, 0x01 = default
    var sessionType: UInt8 = 0x03

    init(transport: OBDelevenTransport) {
        self.transport = transport
    }

    // MARK: Setup

    struct OpenReport {
        var steps: [String]
        /// True when the ECU answered at least one request, i.e. the CAN ids are right.
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
                       + (answered ? " answers" : " silent"))
        return OpenReport(steps: steps, answered: answered)
    }

    /// One read-only request used to tell whether the bus and ids are right.
    func identification() async -> (ok: Bool, detail: String) {
        do {
            let response = try await send([0x22, 0xF1, 0x87])
            return (response.first == 0x62, response.isEmpty ? "tomt svar" : response.hex)
        } catch {
            return (false, Self.short(error))
        }
    }

    static func short(_ error: Error) -> String {
        if let obd = error as? OBDError { return obd.errorDescription ?? "fel" }
        return error.localizedDescription
    }

    // MARK: Core

    @discardableResult
    func send(_ payload: [UInt8], retries: Int = 3) async throws -> [UInt8] {
        var attempt = 0
        while true {
            let response = try await transport.uds(payload)

            if response.count >= 3, response[0] == 0x7F {
                let code = response[2]
                if (code == 0x21 || code == 0x23), attempt < retries {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                throw OBDError.nrc(code)
            }
            // `21 00` is the adapter saying "request sent, nothing came back".
            // Treating it as a successful empty answer made the ECU look open.
            if response.isEmpty { throw OBDError.badResponse("tomt svar (inget från modulen)") }
            return response
        }
    }

    func testerPresent() async {
        _ = try? await send([0x3E, 0x00])
    }

    // MARK: Data

    func readDID(_ did: UInt16) async throws -> [UInt8] {
        let response = try await send([0x22, UInt8(did >> 8), UInt8(did & 0xFF)])
        guard response.count >= 3, response[0] == 0x62 else {
            throw OBDError.badResponse(response.hex)
        }
        return Array(response[3...])
    }

    // MARK: Routines

    func startRoutine(_ rid: UInt16, parameters: [UInt8] = []) async throws -> [UInt8] {
        try await send([0x31, 0x01, UInt8(rid >> 8), UInt8(rid & 0xFF)] + parameters)
    }

    func stopRoutine(_ rid: UInt16) async throws -> [UInt8] {
        try await send([0x31, 0x02, UInt8(rid >> 8), UInt8(rid & 0xFF)])
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

        _ = try await startRoutine(rid, parameters: parameters)
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

            // status byte: 0x00 not active, 0x01 running, 0x02 finished ok, 0x03 finished with error
            if last.count >= 4 {
                let status = last[3]
                if status == 0x00 || status == 0x02 || status == 0x03 {
                    return last
                }
            } else {
                return last
            }
        }
        throw OBDError.timeout
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
