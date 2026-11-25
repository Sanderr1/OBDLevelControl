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

    enum Kind: Equatable { case proto, command, ioCtl, device(UInt8) }

    /// How bytes are framed on the way out, and how the write is declared to iOS.
    /// `auto` is the normal path. The explicit values are what
    /// `Prova alla länklägen` leaves behind once one combination has answered, so
    /// the next connect goes straight to it instead of timing out first.
    enum WireForm: String { case auto, framed, raw }
    enum WriteStyle: String { case auto, withResponse, withoutResponse }

    static let svcData = CBUUID(string: "FFE0")
    static let chrData = CBUUID(string: "FFE1")
    static let svcCtrl = CBUUID(string: "FFE3")
    static let chrCtrl = CBUUID(string: "FFE4")

    @Published private(set) var statusText = "idle"
    @Published private(set) var ready = false
    @Published private(set) var connectedName = ""
    /// E.g. "FFE1 writeNoResp+notify", shown in Diagnostik.
    @Published private(set) var charInfo = ""
    /// Which wire form the adapter answered in: "ramad" or "rå".
    @Published private(set) var wireMode = "ramad"
    /// What the app is set to send. `auto` until something has answered.
    @Published var wireForm: WireForm = .auto {
        didSet { UserDefaults.standard.set(wireForm.rawValue, forKey: "link.form") }
    }
    @Published var writeStyle: WriteStyle = .auto {
        didSet { UserDefaults.standard.set(writeStyle.rawValue, forKey: "link.style") }
    }
    /// 1 = classic SPP dongle, 2 = BLE, 3 = Pro 3 generation
    @Published private(set) var generation: UInt8?
    @Published var devices: [Discovered] = []
    @Published var log: [String] = []

    private var central: CBCentralManager!
    private var known: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var dataChar: CBCharacteristic?
    private var dataCharProps: CBCharacteristicProperties = []

    private var rx: [UInt8] = []
    private var inbox: [(Kind, [UInt8], UInt8)] = []
    private var pendingKind: Kind?
    private var pendingCont: CheckedContinuation<[UInt8], Error>?
    private var pendingTimer: Task<Void, Never>?
    private var writeCont: CheckedContinuation<Void, Error>?

    /// Wire-level reassembly (0x0F ... escaped ... 0x04)
    private var wireBuffer: [UInt8] = []
    private var wireEscaped = false
    /// Counts frames handed to the parser, so a notification that decodes to
    /// nothing can be retried as a plain reply.
    private var deliveredFrames = 0

    private var gateOpen = true
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    /// Learned per connection: true once a reply arrived for unframed bytes.
    private var wireIsPlain = false
    /// Set after the framed attempt failed, so the fallback runs at most once.
    private var framedFailed = false

    override init() {
        super.init()
        if let raw = UserDefaults.standard.string(forKey: "link.form"),
           let form = WireForm(rawValue: raw) { wireForm = form }
        if let raw = UserDefaults.standard.string(forKey: "link.style"),
           let style = WriteStyle(rawValue: raw) { writeStyle = style }
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
        let payload = try await exchange([0x08], kind: .device(0x08))
        let gen = payload.first ?? 0
        generation = gen
        note("adapter generation \(gen)")
        return gen
    }

    func setGeneration(_ gen: UInt8) {
        generation = gen
    }

    /// Device-level query that answers without any CAN setup: 0x10 version,
    /// 0x12 serial number, 0x16 adapter voltage.
    func deviceQuery(_ code: UInt8, timeout: TimeInterval = 5) async throws -> [UInt8] {
        try await exchange([code], kind: .device(code), timeout: timeout)
    }

    /// "ramad + med kvittens" — what the app is currently set to send.
    var linkModeText: String { Self.label(wireForm) + " + " + Self.label(writeStyle) }

    /// Sweeps the four ways the same `08` can be sent and keeps the first one that
    /// answers. `08` asks the adapter for its generation and needs no car, so this
    /// separates "the link is wrong" from "the CAN ids are wrong" without guessing.
    @discardableResult
    func probeLink(timeout: TimeInterval = 2.5) async -> String {
        guard ready else { return "länk: adaptern är inte ansluten" }
        var tried: [String] = []
        for form in [WireForm.framed, .raw] {
            for style in [WriteStyle.withResponse, .withoutResponse] {
                wireForm = form
                writeStyle = style
                clearWire()
                do {
                    let answer = try await deviceQuery(0x08, timeout: timeout)
                    if let gen = answer.first { generation = gen }
                    let text = "länk: \(Self.label(form)) + \(Self.label(style)) svarar · 08 → \(answer.hex)"
                    note(text)
                    statusText = text
                    return text
                } catch {
                    tried.append("\(Self.label(form)) + \(Self.label(style)): \(ECUConnection.short(error))")
                }
            }
        }
        // Nothing answered. Hand control back to the normal fallback chain.
        wireForm = .auto
        writeStyle = .auto
        let text = "länk: ingen kombination svarade (" + tried.joined(separator: " · ") + ")"
        note(text)
        statusText = text
        return text
    }

    private static func label(_ form: WireForm) -> String {
        switch form {
        case .auto: return "auto"
        case .framed: return "ramad"
        case .raw: return "rå"
        }
    }

    private static func label(_ style: WriteStyle) -> String {
        switch style {
        case .auto: return "auto"
        case .withResponse: return "med kvittens"
        case .withoutResponse: return "utan kvittens"
        }
    }

    /// `width` is how many bytes the 0x22 ioctl carries per id. Four is what the
    /// Android client uses, and the bytes are **little-endian**: `Converter.g()`
    /// builds `(id >> 0), (id >> 8), (id >> 16), (id >> 24)`. A 29-bit id sets bit
    /// 31 (`id | 0x80000000`) before it is written, the same way
    /// `ConnectToUdsExtendedUC` does.
    func setCAN(tx: UInt32, rx: UInt32, width: Int = 4, extended: Bool = false) async throws {
        _ = try await exchange([0x22, 0x00] + Self.idBytes(rx, width: width, extended: extended), kind: .ioCtl)
        _ = try await exchange([0x22, 0x01] + Self.idBytes(tx, width: width, extended: extended), kind: .ioCtl)
    }

    func uds(_ payload: [UInt8], timeout: TimeInterval = 5) async throws -> [UInt8] {
        let n = payload.count
        let frame: [UInt8] = [0x21, UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF)] + payload
        return try await exchange(frame, kind: .command, timeout: timeout)
    }

    /// Little-endian, because that is the only order the adapter has ever been
    /// shown to accept. The previous big-endian order made `0x77E` go out as
    /// `00 00 07 7E`, so the adapter filtered on the wrong id, heard nothing and
    /// answered every UDS request with `21 FE` (`RESULT_NOT_CONNECTED`).
    static func idBytes(_ id: UInt32, width: Int = 4, extended: Bool = false) -> [UInt8] {
        let value = extended ? (id | 0x8000_0000) : id
        if width == 2 { return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
        return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    // MARK: Internals

    private func exchange(_ frame: [UInt8], kind: Kind, timeout: TimeInterval = 5) async throws -> [UInt8] {
        await acquire()
        defer { release() }

        guard ready, let peripheral = active, let ch = dataChar else { throw OBDError.notConnected }

        // Which framings to try. An explicit mode (set by `probeLink`) is used
        // alone; `auto` keeps the learned chain: framed first, then raw, but never
        // more than two attempts per command.
        let forms: [Bool]
        switch wireForm {
        case .framed: forms = [false]
        case .raw: forms = [true]
        case .auto: forms = (wireIsPlain || framedFailed) ? [true, false] : [false, true]
        }

        var lastError: Error = OBDError.timeout
        for (index, plain) in forms.enumerated() {
            note((plain ? ">r " : "> ") + frame.hex)
            do {
                try await write(plain ? frame : Self.encode(frame), to: peripheral, char: ch, style: writeStyle)
                let limit = index == 0 ? timeout : min(timeout, 2)
                let response = try await waitResponse(kind: kind, timeout: limit)
                wireIsPlain = plain
                wireMode = plain ? "rå" : "ramad"
                note((plain ? "<r " : "< ") + response.hex)
                try? await Task.sleep(nanoseconds: 15_000_000)
                return response
            } catch {
                lastError = error
                var isTimeout = false
                if let obd = error as? OBDError, case .timeout = obd { isTimeout = true }
                guard isTimeout else { throw error }
                if !plain { framedFailed = true }
                note("timeout, nollställer bufferten")
                clearWire()
            }
        }
        throw lastError
    }

    private func clearWire() {
        rx.removeAll()
        wireBuffer.removeAll()
        wireEscaped = false
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

    /// 20-byte chunks is what the Android client writes, so keep that. The write
    /// type has to follow the characteristic: some Pro units only expose
    /// `writeWithoutResponse` on FFE1, and asking for a response there fails
    /// silently once the error is swallowed.
    private func write(_ bytes: [UInt8], to peripheral: CBPeripheral,
                       char: CBCharacteristic, style: WriteStyle = .auto) async throws {
        let props = char.properties
        let useResponse: Bool
        switch style {
        case .withResponse:
            useResponse = true
        case .withoutResponse:
            useResponse = false
        case .auto:
            if props.contains(.write) { useResponse = true }
            else if props.contains(.writeWithoutResponse) { useResponse = false }
            else { throw OBDError.badResponse("FFE1 kan inte ta emot data (\(Self.describe(props)))") }
        }
        if useResponse && !props.contains(.write) {
            throw OBDError.badResponse("FFE1 saknar write (\(Self.describe(props)))")
        }
        if !useResponse && !props.contains(.writeWithoutResponse) {
            throw OBDError.badResponse("FFE1 saknar writeNoResp (\(Self.describe(props)))")
        }
        var i = 0
        while i < bytes.count {
            let end = min(i + 20, bytes.count)
            let chunk = Data(bytes[i..<end])
            if useResponse {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    writeCont = c
                    peripheral.writeValue(chunk, for: char, type: .withResponse)
                }
            } else {
                var spins = 0
                while !peripheral.canSendWriteWithoutResponse && spins < 200 {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    spins += 1
                }
                peripheral.writeValue(chunk, for: char, type: .withoutResponse)
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
            i = end
        }
    }

    static func describe(_ props: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if props.contains(.read) { parts.append("read") }
        if props.contains(.write) { parts.append("write") }
        if props.contains(.writeWithoutResponse) { parts.append("writeNoResp") }
        if props.contains(.notify) { parts.append("notify") }
        if props.contains(.indicate) { parts.append("indicate") }
        return parts.isEmpty ? "inga" : parts.joined(separator: "+")
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
        deliveredFrames += 1
        if let cont = pendingCont, pendingKind == kind {
            pendingCont = nil
            pendingKind = nil
            pendingTimer?.cancel()
            pendingTimer = nil
            if err != 0 { cont.resume(throwing: OBDError.deviceError(err)) }
            else { cont.resume(returning: payload) }
        } else {
            // Nothing was waiting for this frame. Log it: a reply that arrives for
            // the wrong command is otherwise invisible, and that is exactly how the
            // first working answer from the adapter was missed.
            note("osoliciterat svar " + payload.hex + (err == 0 ? "" : String(format: " (fel 0x%02X)", err)))
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
                deliver(.device(0x08), [gen], err)

            case 0x21:
                guard rx.count >= 2 else { return }
                let err = rx[1]
                if err != 0 {
                    // `21 <err>`: a negative answer carries no length field. The
                    // adapter says this when the module on the bus said nothing
                    // (0xFE), and it must surface as an error, not as a timeout.
                    rx.removeFirst(2)
                    deliver(.command, [], err)
                    continue
                }
                guard rx.count >= 4 else {
                    // `21 00` with nothing after it: the request reached the
                    // adapter, the module returned no data. Answering with an
                    // empty payload beats waiting for bytes that never come.
                    rx.removeFirst(2)
                    deliver(.command, [], 0)
                    continue
                }
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

            case 0x10, 0x12, 0x16, 0x1C:
                // Device-level replies (version, serial, voltage, full version) are
                // "<code> <err> <data...>" and have no length field.
                guard rx.count >= 2 else { return }
                let code = rx[0]
                let err = rx[1]
                let payload = Array(rx.dropFirst(2))
                rx.removeAll()
                deliver(.device(code), payload, err)

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
        dataCharProps = []
        connectedName = ""
        generation = nil
        rx.removeAll()
        inbox.removeAll()
        wireBuffer.removeAll()
        wireEscaped = false
        wireIsPlain = false
        framedFailed = false
        deliveredFrames = 0
        charInfo = ""
        wireMode = "ramad"
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
        peripheral.discoverServices(nil)
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
            note("tjanst \(service.uuid)")
            // Enumerate everything, not just the two known ones: the Pro 3 may
            // expose extra characteristics and we want to see them in the log.
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }
        for c in chars {
            note("  \(c.uuid): \(Self.describe(c.properties))")
        }
        for c in chars where c.uuid == Self.chrData {
            dataChar = c
            dataCharProps = c.properties
            charInfo = "FFE1 " + Self.describe(c.properties)
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
        Task {
            // A stored mode is trusted first; if it no longer works, sweep again.
            if self.wireForm != .auto && self.writeStyle != .auto {
                do { try await self.readGeneration() }
                catch { await self.probeLink() }
            } else {
                await self.probeLink()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        let bytes = [UInt8](data)
        // Log every byte that arrives. Without this line a reply that the decoder
        // cannot parse is indistinguishable from no reply at all.
        note("rx " + bytes.hex)

        let before = deliveredFrames
        receive(bytes)
        guard deliveredFrames == before else { return }

        // Some firmware builds answer with the plain command bytes instead of a
        // 0x0F frame. Retry the notification as a bare reply in that case.
        if bytes.count >= 2, bytes.last != 0x04,
           [0x08, 0x20, 0x21, 0x22].contains(bytes[0]) {
            note("rx utan 0F-ram")
            wireBuffer.removeAll()
            wireEscaped = false
            rx.append(contentsOf: bytes)
            drain()
        }
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
