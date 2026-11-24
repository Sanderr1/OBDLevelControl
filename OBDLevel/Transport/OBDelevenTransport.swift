import Foundation
import CoreBluetooth

// MARK: - Errors

enum OBDError: LocalizedError {
    case bluetoothUnavailable
    case notConnected
    case timeout
    case deviceError(UInt8)
    case nrc(UInt8)
    case badResponse(String)
    case securityKeyMissing

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: return "Bluetooth unavailable"
        case .notConnected: return "Adapter not connected"
        case .timeout: return "No response (timeout)"
        case .deviceError(let c): return String(format: "Adapter error 0x%02X", c)
        case .nrc(let c): return String(format: "NRC 0x%02X %@", c, NRC.text(c))
        case .badResponse(let s): return "Unexpected response: \(s)"
        case .securityKeyMissing: return "ECU wants security access and no key algorithm was supplied"
        }
    }
}

enum NRC {
    static func text(_ code: UInt8) -> String {
        switch code {
        case 0x10: return "generalReject"
        case 0x11: return "serviceNotSupported"
        case 0x12: return "subFunctionNotSupported"
        case 0x13: return "incorrectMessageLength"
        case 0x21: return "busyRepeatRequest"
        case 0x22: return "conditionsNotCorrect"
        case 0x23: return "routineNotComplete"
        case 0x24: return "requestSequenceError"
        case 0x31: return "requestOutOfRange"
        case 0x33: return "securityAccessDenied"
        case 0x35: return "invalidKey"
        case 0x36: return "exceededAttempts"
        case 0x37: return "requiredTimeDelayNotExpired"
        case 0x72: return "generalProgrammingFailure"
        case 0x78: return "responsePending"
        default: return "unknown"
        }
    }
}

enum DeviceProtocol: UInt8 {
    case can = 0x01
    case isoTP = 0x02
    case tp20 = 0x03
    case tp16 = 0x04
    case kLine = 0x05
    case isoTPOBD2 = 0x06
}

// MARK: - Transport

/// Frames bytes for the OBDeleven adapter (2nd gen, BLE) and speaks its command protocol.
///
/// Wire format observed in the Android client:
///   0x20 <proto>                                set transport protocol, reply 0x20 <err>
///   0x21 <lenLo> <lenHi> <payload...>           request,     reply 0x21 <err> <lenLo> <lenHi> <data...>
///   0x22 <sub> <data...>                        ioctl,       reply 0x22 <err> <data...>
///      sub 0x00 = CAN receive filter id, 0x01 = CAN transmit id
final class OBDelevenTransport: NSObject, ObservableObject {

    struct Discovered: Identifiable, Hashable {
        let id: UUID
        let name: String
    }

    enum Kind { case proto, command, ioCtl, generation }

    static let svcData = CBUUID(string: "FFE0")
    static let chrData = CBUUID(string: "FFE1")
    static let svcCtrl = CBUUID(string: "FFE3")
    static let chrCtrl = CBUUID(string: "FFE4")

    @Published private(set) var statusText = "idle"
    @Published private(set) var ready = false
    @Published private(set) var connectedName = ""
    /// 1 = classic SPP dongle, 2 = BLE, 3 = Pro 3 generation
    @Published private(set) var generation: UInt8?
    @Published var devices: [Discovered] = []
    @Published var log: [String] = []

    private var central: CBCentralManager!
    private var known: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var dataChar: CBCharacteristic?

    private var rx: [UInt8] = []
    private var inbox: [(Kind, [UInt8], UInt8)] = []
    private var pendingKind: Kind?
    private var pendingCont: CheckedContinuation<[UInt8], Error>?
    private var pendingTimer: Task<Void, Never>?
    private var writeCont: CheckedContinuation<Void, Error>?

    /// Wire-level reassembly (0x0F ... escaped ... 0x04)
    private var wireBuffer: [UInt8] = []
    private var wireEscaped = false

    private var gateOpen = true
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Lifecycle

    func startScan() {
        guard central.state == .poweredOn else {
            statusText = "bluetooth state \(central.state.rawValue)"
            return
        }
        devices.removeAll()
        central.scanForPeripherals(withServices: [Self.svcData, Self.svcCtrl],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        statusText = "scanning"
    }

    func stopScan() { central.stopScan() }

    func connect(_ id: UUID) {
        guard let p = known[id] else { return }
        central.stopScan()
        statusText = "connecting"
        central.connect(p, options: nil)
    }

    func disconnect() {
        if let p = active { central.cancelPeripheralConnection(p) }
    }

    func note(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: Frame API

    func setProtocol(_ proto: DeviceProtocol) async throws {
        _ = try await exchange([0x20, proto.rawValue], kind: .proto)
    }

    /// 0x08 -> 0x08 0x00 <generation>. 3 = Pro 3 hardware.
    @discardableResult
    func readGeneration() async throws -> UInt8 {
        let payload = try await exchange([0x08], kind: .generation)
        let gen = payload.first ?? 0
        generation = gen
        note("adapter generation \(gen)")
        return gen
    }

    func setCAN(tx: UInt32, rx: UInt32) async throws {
        _ = try await exchange([0x22, 0x00] + Self.idBytes(rx), kind: .ioCtl)
        _ = try await exchange([0x22, 0x01] + Self.idBytes(tx), kind: .ioCtl)
    }

    func uds(_ payload: [UInt8], timeout: TimeInterval = 5) async throws -> [UInt8] {
        let n = payload.count
        let frame: [UInt8] = [0x21, UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF)] + payload
        return try await exchange(frame, kind: .command, timeout: timeout)
    }

    static func idBytes(_ id: UInt32) -> [UInt8] {
        [UInt8((id >> 24) & 0xFF), UInt8((id >> 16) & 0xFF), UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)]
    }

    // MARK: Internals

    private func exchange(_ frame: [UInt8], kind: Kind, timeout: TimeInterval = 5) async throws -> [UInt8] {
        await acquire()
        defer { release() }

        guard ready, let peripheral = active, let ch = dataChar else { throw OBDError.notConnected }
        note("> " + frame.hex)

        let wire = Self.encode(frame)
        try await write(wire, to: peripheral, char: ch)
        let response = try await waitResponse(kind: kind, timeout: timeout)
        note("< " + response.hex)
        try? await Task.sleep(nanoseconds: 15_000_000)
        return response
    }

    // MARK: Wire codec

    /// key rotation used by DeviceBase.a(): ror(key, 1) after every byte
    private static func rotate(_ key: UInt8) -> UInt8 {
        UInt8(((UInt16(key) >> 1) | (UInt16(key) << 7)) & 0xFF)
    }

    /// CRC-16/XMODEM: init 0, poly 0x1021, MSB first.
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            for bit in 0..<8 {
                let dataBit = (byte >> UInt8(7 - bit)) & 1
                let topBit = UInt8((crc >> 15) & 1)
                crc = (crc << 1) & 0xFFFF
                if (dataBit ^ topBit) == 1 { crc ^= 0x1021 }
            }
        }
        return crc
    }

    /// Plain command bytes -> what actually goes on the air:
    /// random key byte with bit 7 set, each payload byte XORed with the rotating key,
    /// CRC16 little-endian, then 0x0F ... 0x05-escaped ... 0x04.
    static func encode(_ payload: [UInt8]) -> [UInt8] {
        var key = UInt8.random(in: 0...127) | 0x80
        var body: [UInt8] = [key]
        body.reserveCapacity(payload.count + 3)
        for byte in payload {
            body.append(byte ^ key)
            key = rotate(key)
        }

        let crc = crc16(body)
        body.append(UInt8(crc & 0xFF))
        body.append(UInt8(crc >> 8))

        var wire: [UInt8] = [0x0F]
        wire.reserveCapacity(body.count + 4)
        for byte in body {
            if byte == 0x04 || byte == 0x05 || byte == 0x0F { wire.append(0x05) }
            wire.append(byte)
        }
        wire.append(0x04)
        return wire
    }

    /// 0x0F ... 0x04 frame -> plain command bytes. CRC is dropped, not verified,
    /// exactly like DeviceBase.l().
    static func decode(_ frame: [UInt8]) -> [UInt8] {
        guard frame.count > 2 else { return [] }
        let body = Array(frame.dropLast(2))
        guard let first = body.first else { return [] }
        guard first & 0x80 != 0 else { return body }

        var key = first
        var out: [UInt8] = []
        out.reserveCapacity(body.count - 1)
        for index in 1..<body.count {
            out.append(body[index] ^ key)
            key = rotate(key)
        }
        return out
    }

    private func receive(_ bytes: [UInt8]) {
        for byte in bytes {
            if wireEscaped {
                wireBuffer.append(byte)
                wireEscaped = false
            } else if byte == 0x05 {
                wireEscaped = true
            } else if byte == 0x04 {
                let frame = wireBuffer
                wireBuffer.removeAll(keepingCapacity: true)
                let payload = Self.decode(frame)
                if !payload.isEmpty {
                    rx.append(contentsOf: payload)
                    drain()
                }
            } else if byte == 0x0F {
                wireBuffer.removeAll(keepingCapacity: true)
            } else {
                wireBuffer.append(byte)
            }
        }
    }

    private func write(_ bytes: [UInt8], to peripheral: CBPeripheral, char: CBCharacteristic) async throws {
        var i = 0
        while i < bytes.count {
            let end = min(i + 20, bytes.count)
            let chunk = Data(bytes[i..<end])
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                writeCont = c
                peripheral.writeValue(chunk, for: char, type: .withResponse)
            }
            i = end
        }
    }

    private func waitResponse(kind: Kind, timeout: TimeInterval) async throws -> [UInt8] {
        if let idx = inbox.firstIndex(where: { $0.0 == kind }) {
            let frame = inbox.remove(at: idx)
            if frame.2 != 0 { throw OBDError.deviceError(frame.2) }
            return frame.1
        }

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[UInt8], Error>) in
            pendingKind = kind
            pendingCont = c
            pendingTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard let cont = self.pendingCont else { return }
                self.pendingCont = nil
                self.pendingKind = nil
                cont.resume(throwing: OBDError.timeout)
            }
        }
    }

    private func deliver(_ kind: Kind, _ payload: [UInt8], _ err: UInt8) {
        if let cont = pendingCont, pendingKind == kind {
            pendingCont = nil
            pendingKind = nil
            pendingTimer?.cancel()
            pendingTimer = nil
            if err != 0 { cont.resume(throwing: OBDError.deviceError(err)) }
            else { cont.resume(returning: payload) }
        } else {
            inbox.append((kind, payload, err))
            if inbox.count > 16 { inbox.removeFirst() }
        }
    }

    private func drain() {
        while !rx.isEmpty {
            switch rx[0] {
            case 0x20:
                guard rx.count >= 2 else { return }
                let err = rx[1]
                rx.removeFirst(2)
                deliver(.proto, [], err)

            case 0x08:
                guard rx.count >= 3 else { return }
                let err = rx[1]
                let gen = rx[2]
                rx.removeFirst(3)
                deliver(.generation, [gen], err)

            case 0x21:
                guard rx.count >= 4 else { return }
                let err = rx[1]
                let len = Int(rx[2]) | (Int(rx[3]) << 8)
                guard rx.count >= 4 + len else { return }
                let payload = Array(rx[4..<(4 + len)])
                rx.removeFirst(4 + len)
                deliver(.command, payload, err)

            case 0x22:
                guard rx.count >= 2 else { return }
                let err = rx[1]
                let payload = Array(rx.dropFirst(2))
                rx.removeAll()
                deliver(.ioCtl, payload, err)

            default:
                rx.removeFirst()
            }
        }
    }

    private func acquire() async {
        if gateOpen { gateOpen = false; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            gateWaiters.append(c)
        }
    }

    private func release() {
        if gateWaiters.isEmpty { gateOpen = true }
        else { gateWaiters.removeFirst().resume() }
    }

    private func resetConnectionState() {
        ready = false
        dataChar = nil
        connectedName = ""
        generation = nil
        rx.removeAll()
        inbox.removeAll()
        wireBuffer.removeAll()
        wireEscaped = false
    }
}

// MARK: - Central delegate

extension OBDelevenTransport: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        statusText = "bluetooth state \(central.state.rawValue)"
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        known[peripheral.identifier] = peripheral
        guard !devices.contains(where: { $0.id == peripheral.identifier }) else { return }
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "unnamed"
        devices.append(Discovered(id: peripheral.identifier, name: name))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        active = peripheral
        connectedName = peripheral.name ?? "adapter"
        statusText = "discovering"
        peripheral.delegate = self
        peripheral.discoverServices([Self.svcData, Self.svcCtrl])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        statusText = "connect failed: \(error?.localizedDescription ?? "unknown")"
        resetConnectionState()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        statusText = "disconnected"
        active = nil
        resetConnectionState()
    }
}

// MARK: - Peripheral delegate

extension OBDelevenTransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services {
            if service.uuid == Self.svcData {
                peripheral.discoverCharacteristics([Self.chrData], for: service)
            } else if service.uuid == Self.svcCtrl {
                peripheral.discoverCharacteristics([Self.chrCtrl], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }
        for c in chars where c.uuid == Self.chrData {
            dataChar = c
            peripheral.setNotifyValue(true, for: c)
            statusText = "enabling notifications"
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.chrData else { return }
        if let error {
            statusText = "notify failed: \(error.localizedDescription)"
            return
        }
        guard characteristic.isNotifying else { return }
        dataChar = characteristic
        ready = true
        statusText = "ready"
        note("linked to \(peripheral.name ?? "adapter")")
        Task { try? await self.readGeneration() }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        receive([UInt8](data))
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let cont = writeCont else { return }
        writeCont = nil
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }
}

// MARK: - Helpers

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

extension String {
    /// "22 F1 87" / "22F187" -> [0x22, 0xF1, 0x87]
    var hexBytes: [UInt8]? {
        let clean = filter { !$0.isWhitespace && $0 != ":" && $0 != "-" && $0 != "," }
        guard clean.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }
}
