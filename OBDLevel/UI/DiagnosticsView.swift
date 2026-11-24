import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject var transport: OBDelevenTransport
    @EnvironmentObject var service: LevelControlService
    @EnvironmentObject var demo: DemoModel

    @State private var input = "22 F1 90"

    var body: some View {
        VStack(spacing: 18) {
            infoSection
            sensorSection
            consoleSection
            logSection
        }
    }

    // MARK: Info

    private var infoSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Diagnostik", trailing: demo.enabled ? "Demo" : "Live")

            Card {
                ValueRow(title: "Styrenhet",
                         value: String(format: "%03X → %03X", service.profile.txId, service.profile.rxId))
                HairLine()
                ValueRow(title: "OBD-adapter", value: adapterText)
                HairLine()
                ValueRow(title: "Kommunikation",
                         value: transport.ready ? "Etablerad" : "Ej etablerad",
                         valueColor: transport.ready ? Palette.green : Palette.muted)
                HairLine()
                ValueRow(title: "Protokoll", value: "UDS · ISO-TP")
                HairLine()
                ValueRow(title: "Felkoder", value: "Ej avlästa")
                HairLine()
                ValueRow(title: "Nivåreglering", value: levelText)
                HairLine()
                HStack(spacing: 8) {
                    ActionButton(title: "Testa anslutning",
                                 enabled: !demo.enabled && transport.ready && !service.busy) {
                        Task { await service.runSelfTest() }
                    }
                }
                .padding(11)
            }
        }
    }

    private var adapterText: String {
        guard transport.ready else { return "Ej ansluten" }
        let name = transport.connectedName.isEmpty ? "Adapter" : transport.connectedName
        guard let gen = transport.generation else { return name }
        return gen == 3 ? "\(name) · Pro 3" : "\(name) · gen \(gen)"
    }

    private var levelText: String {
        if demo.enabled { return demo.levelOn ? "På (demo)" : "Av (demo)" }
        return service.levelControlEnabled ? "På (appens läge)" : "Av (appens läge)"
    }

    // MARK: Sensor values

    private var sensorSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Sensorvärden", trailing: "\(decodedCount) av \(service.profile.channels.count)")

            Card {
                ForEach(service.profile.channels.indices, id: \.self) { index in
                    if index > 0 { HairLine() }
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.profile.channels[index].name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                            Text(String(format: "DID %04X", service.profile.channels[index].did))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(decodedText(index))
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(Palette.ink)
                            Text(rawText(index))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var decodedCount: Int {
        service.readings.reduce(into: 0) { count, reading in
            if reading.value != nil { count += 1 }
        }
    }

    private func decodedText(_ index: Int) -> String {
        guard index < service.readings.count else { return "–" }
        return formatValue(service.readings[index].value, decimals: 1)
    }

    private func rawText(_ index: Int) -> String {
        guard index < service.readings.count else { return "–" }
        return service.readings[index].raw
    }

    // MARK: Console

    private var consoleSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Konsol", trailing: "UDS hex")

            Card {
                HStack(spacing: 8) {
                    TextField("22 F1 90", text: $input)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .textFieldStyle(.plain)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(Palette.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Palette.line, lineWidth: 1)
                        )
                    ActionButton(title: "Sänd", enabled: canSend) {
                        Task { await service.rawCommand(input) }
                    }
                    .frame(width: 74)
                }
                .padding(11)

                HairLine()

                Text(service.statusLine.isEmpty ? "Inget kommando skickat." : service.statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
    }

    private var canSend: Bool {
        !demo.enabled && transport.ready && !service.busy
    }

    // MARK: Log

    private var logSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Logg", trailing: "\(transport.log.count) rader")

            Card {
                VStack(alignment: .leading, spacing: 3) {
                    if transport.log.isEmpty {
                        Text("Tom logg.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                    } else {
                        ForEach(recentLog.indices, id: \.self) { index in
                            Text(recentLog[index])
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Palette.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(11)
            }
        }
    }

    private var recentLog: [String] {
        Array(transport.log.suffix(40))
    }
}
