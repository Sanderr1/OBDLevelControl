import Foundation

/// A physically plausible reading of one DID response.
///
/// The ODX pack knows the scaling; we do not. So instead of trusting one formula,
/// every response is decoded with a handful of standard VAG scalings and kept only
/// if the result lands in a band where that kind of value can realistically live.
struct ValueCandidate {
    let did: UInt16
    let kind: ValueKind
    let value: Double
    let length: Int
    let scale: Double
    let signed: Bool
}

enum ValueKind {
    case voltage
    case pressure
    case temperature
    case distance
}

enum ValueProbe {

    /// Typical value for each kind, used to rank competing interpretations.
    static func typical(_ kind: ValueKind) -> Double {
        switch kind {
        case .voltage: return 12.6
        case .pressure: return 8
        case .temperature: return 25
        case .distance: return 380
        }
    }

    /// 1 = exactly the typical value, lower = further away. Never zero.
    static func confidence(_ candidate: ValueCandidate) -> Double {
        let target = typical(candidate.kind)
        return 1 / (1 + abs(candidate.value - target) / target)
    }

    static func plausible(_ kind: ValueKind, _ value: Double) -> Bool {
        switch kind {
        case .voltage: return value >= 8 && value <= 16.5
        case .pressure: return value >= 0.5 && value <= 20
        case .temperature: return value >= -40 && value <= 150
        case .distance: return value >= 250 && value <= 500
        }
    }

    static func decode(_ data: [UInt8], length: Int, scale: Double, signed: Bool) -> Double? {
        guard length > 0, length <= 4, data.count >= length else { return nil }
        var raw: UInt32 = 0
        for i in 0..<length { raw = (raw << 8) | UInt32(data[i]) }

        let value: Double
        if signed {
            let bits = length * 8
            let signBit = UInt32(1) << (bits - 1)
            if raw & signBit != 0 {
                value = Double(Int64(raw) - (Int64(1) << bits))
            } else {
                value = Double(raw)
            }
        } else {
            value = Double(raw)
        }
        return value * scale
    }

    /// Scalings worth trying. Big-endian, like every VAG DID.
    /// Battery: millivolts or tenths of a volt. Pressure: 0.001/0.01/0.1 bar.
    /// Temperature: plain °C or 0.1 °C. Height: signed 0.1 mm (and 0.01 as a fallback).
    private static let attempts: [(length: Int, scale: Double, signed: Bool, kind: ValueKind)] = [
        (2, 0.001, false, .voltage),
        (1, 0.1, false, .voltage),
        (2, 0.01, false, .pressure),
        (2, 0.1, false, .pressure),
        (2, 0.001, false, .pressure),
        (1, 1, false, .temperature),
        (2, 0.1, false, .temperature),
        (2, 0.1, true, .distance),
        (2, 0.01, true, .distance),
        (2, 0.1, false, .distance)
    ]

    /// Every plausible interpretation of a response, most likely first.
    static func candidates(did: UInt16, data: [UInt8]) -> [ValueCandidate] {
        var out: [ValueCandidate] = []
        for attempt in attempts {
            guard data.count >= attempt.length,
                  let value = decode(data, length: attempt.length, scale: attempt.scale, signed: attempt.signed),
                  plausible(attempt.kind, value) else { continue }
            out.append(ValueCandidate(did: did,
                                      kind: attempt.kind,
                                      value: value,
                                      length: attempt.length,
                                      scale: attempt.scale,
                                      signed: attempt.signed))
        }
        return out.sorted { confidence($0) > confidence($1) }
    }

    /// One interpretation per DID — the single most likely one. Keeps a height DID
    /// from also being offered as a pressure reading because of a lucky scaling.
    static func bestPerDID(_ candidates: [ValueCandidate]) -> [ValueCandidate] {
        var best: [UInt16: ValueCandidate] = [:]
        for candidate in candidates {
            if let existing = best[candidate.did],
               confidence(existing) >= confidence(candidate) { continue }
            best[candidate.did] = candidate
        }
        return Array(best.values)
    }
}
