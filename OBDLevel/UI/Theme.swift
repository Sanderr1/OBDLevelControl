import SwiftUI

// MARK: - Palette (taken from obd-height-controller.html)

enum Palette {
    static let bg = Color(rgb: 0x0D1016)
    static let surface = Color(rgb: 0x191F29)
    static let surfaceAlt = Color(rgb: 0x141922)
    static let line = Color(rgb: 0x2B3340)
    static let muted = Color(rgb: 0xA3ADBC)
    static let ink = Color(rgb: 0xF4F6FA)
    static let blue = Color(rgb: 0xA5C8FF)
    static let amber = Color(rgb: 0xFFD183)
    static let tabActive = Color(rgb: 0x2A3547)
    static let button = Color(rgb: 0x23334D)
    static let buttonLine = Color(rgb: 0x3B5376)
    static let buttonInk = Color(rgb: 0xE1EDFF)
    static let switchOn = Color(rgb: 0x3265A8)
    static let green = Color(rgb: 0x6FDD9B)
    static let danger = Color(rgb: 0x3A1F27)
    static let dangerLine = Color(rgb: 0x8E4A58)
    static let dangerInk = Color(rgb: 0xFFD9DE)
}

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255.0,
                  green: Double((rgb >> 8) & 0xFF) / 255.0,
                  blue: Double(rgb & 0xFF) / 255.0,
                  opacity: 1.0)
    }
}

// MARK: - Formatting

func formatValue(_ value: Double?, decimals: Int) -> String {
    guard let value else { return "–" }
    let text = String(format: "%.\(decimals)f", value)
    return text.replacingOccurrences(of: ".", with: ",")
}

// MARK: - Primitives

struct HairLine: View {
    var body: some View {
        Rectangle()
            .fill(Palette.line)
            .frame(height: 1)
    }
}

struct SectionHeading: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.amber)
            }
        }
    }
}

struct Card<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Palette.line, lineWidth: 1)
            )
    }
}

struct ValueRow: View {
    let title: String
    var value: String = ""
    var valueColor: Color = Palette.ink

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
    }
}

struct SwitchRow: View {
    let title: String
    var detail: String? = nil
    var enabled: Bool = true
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(enabled ? Palette.ink : Palette.muted)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Palette.switchOn)
                .disabled(!enabled)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(minHeight: 58)
    }
}

struct WheelCard: View {
    let title: String
    let text: String
    var unit: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(text)
                    .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Palette.line, lineWidth: 1)
        )
    }
}

struct ActionButton: View {
    let title: String
    var running: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(enabled ? Palette.buttonInk : Palette.muted)
                .background(enabled ? Palette.button : Palette.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(running ? Palette.blue : (enabled ? Palette.buttonLine : Palette.line),
                                lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Two big primary controls on the overview. Slam is deliberately red-toned;
/// Normal uses the ordinary blue button palette.
struct BigActionButton: View {
    let title: String
    let subtitle: String
    var destructive: Bool = false
    var running: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    private var fill: Color { destructive ? Palette.danger : Palette.button }
    private var border: Color { destructive ? Palette.dangerLine : Palette.buttonLine }
    private var ink: Color { destructive ? Palette.dangerInk : Palette.buttonInk }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .foregroundStyle(enabled ? ink : Palette.muted)
            .background(enabled ? fill : Palette.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(running ? Palette.blue : (enabled ? border : Palette.line),
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct FieldCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Palette.muted)
    }
}

struct FieldBox<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Palette.line, lineWidth: 1)
            )
    }
}

struct HexField: View {
    let label: String
    @Binding var value: UInt32
    var digits: Int = 4

    @State private var text = ""
    @State private var seeded = false

    var body: some View {
        FieldBox {
            VStack(alignment: .leading, spacing: 2) {
                FieldCaption(text: label)
                TextField("", text: $text)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .textFieldStyle(.plain)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onAppear {
                        if !seeded {
                            text = formatted(value)
                            seeded = true
                        }
                    }
                    .onChange(of: text) { _, newValue in
                        let clean = String(newValue.uppercased().filter { $0.isHexDigit }.prefix(digits))
                        if clean != newValue { text = clean }
                        if clean.count == digits, let parsed = UInt32(clean, radix: 16) {
                            value = parsed
                        }
                    }
                    .onChange(of: value) { _, newValue in
                        if UInt32(text, radix: 16) != newValue {
                            text = formatted(newValue)
                        }
                    }
            }
        }
    }

    private func formatted(_ v: UInt32) -> String {
        String(format: "%0\(digits)X", v)
    }
}

extension Binding {
    /// Adapts a binding to another value type, e.g. UInt16 <-> UInt32 for hex fields.
    func adapted<T>(get: @escaping (Value) -> T, set: @escaping (T) -> Value) -> Binding<T> {
        let base = self
        return Binding<T>(get: { get(base.wrappedValue) }, set: { base.wrappedValue = set($0) })
    }
}
