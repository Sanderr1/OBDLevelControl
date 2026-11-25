import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @EnvironmentObject var transport: OBDelevenTransport
    @EnvironmentObject var service: LevelControlService
    @EnvironmentObject var demo: DemoModel

    @State private var input = "22 F1 90"
    @State private var showDetails = false
    @State private var showSensors = false
    @State private var showConsole = false
    @State private var showLog = true
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            statusSection
            detailsSection
            sensorSection
            consoleSection
            logSection
        }
    }

    // MARK: Status - only what has to be seen at a glance

    private var statusSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Diagnostik", trailing: demo.enabled ? "Demo" : "Live")

            Card {
                HStack(spacing: 9) {
                    Circle()
                        .fill(summaryColor)
                        .frame(width: 8, height: 8)
                    Text(summaryText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Text(transport.ready ? transport.linkModeText : "—")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 13)

                HairLine()
                ValueRow(title: "Styrenhet",
                         value: String(format: "%03X → %03X", service.profile.txId, service.profile.rxId))
                HairLine()
                ValueRow(title: "Modul 34 svarar",
                         value: service.ecuOpen ? "Ja" : "Nej",
                         valueColor: service.ecuOpen ? Palette.green : Palette.amber)
                HairLine()
                HStack(spacing: 8) {
                    ActionButton(title: "Testa anslutning", enabled: canRun) {
                        Task { await service.runSelfTest() }
                    }
                    ActionButton(title: "Prova länklägen", enabled: canRun) {
                        Task { await service.probeLink() }
                    }
                }
                .padding(11)
            }
        }
    }

    private var summaryText: String {
        if demo.enabled { return "Demoläge" }
        if !transport.ready { return "Ingen adapter" }
        return service.ecuOpen ? "Modul 34 svarar" : "Modul 34 svarar inte"
    }

    private var summaryColor: Color {
        if demo.enabled || !transport.ready { return Palette.amber }
        return service.ecuOpen ? Palette.green : Palette.amber
    }

    private var canRun: Bool {
        !demo.enabled && transport.ready && !service.busy
    }

    // MARK: Details - everything that is only interesting when something is wrong

    private var detailsSection: some View {
        Card {
            DisclosureGroup(isExpanded: $showDetails) {
                VStack(spacing: 0) {
                    HairLine()
                    ValueRow(title: "Adapter", value: adapterText)
                    HairLine()
                    ValueRow(title: "Kommunikation",
                             value: transport.ready ? "Etablerad" : "Ej etablerad",
                             valueColor: transport.ready ? Palette.green : Palette.muted)
                    HairLine()
                    ValueRow(title: "Länk",
                             value: transport.ready
                             ? "\(transport.charInfo) · \(transport.wireMode)"
                             : "—")
                    HairLine()
                    ValueRow(title: "Protokoll", value: "UDS · ISO-TP")
                    HairLine()
                    ValueRow(title: "App", value: AppInfo.build)
                }
            } label: {
                disclosureLabel("Detaljer")
            }
            .tint(Palette.blue)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
        }
    }

    private var adapterText: String {
        guard transport.ready else { return "Ej ansluten" }
        let name = transport.connectedName.isEmpty ? "Adapter" : transport.connectedName
        guard let gen = transport.generation else { return name }
        return gen == 3 ? "\(name) · Pro 3" : "\(name) · gen \(gen)"
    }

    // MARK: Sensor values

    private var sensorSection: some View {
        Card {
            DisclosureGroup(isExpanded: $showSensors) {
                VStack(spacing: 0) {
                    if service.profile.channels.isEmpty {
                        Text("Inga kanaler. Mappa dem under Inställningar.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                    } else {
                        ForEach(service.profile.channels.indices, id: \.self) { index in
                            HairLine()
                            channelRow(index)
                        }
                        if !demo.enabled {
                            HairLine()
                            ActionButton(title: "Läs alla kanaler", enabled: transport.ready && !service.busy) {
                                Task { await service.readAllChannels() }
                            }
                            .padding(11)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Sensorvärden")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Text("\(decodedCount) av \(service.profile.channels.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.amber)
                }
            }
            .tint(Palette.blue)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
        }
    }

    private func channelRow(_ index: Int) -> some View {
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
        Card {
            DisclosureGroup(isExpanded: $showConsole) {
                VStack(spacing: 0) {
                    HairLine()
                    HStack(spacing: 8) {
                        TextField("22 F1 87", text: $input)
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
                        ActionButton(title: "Sänd", enabled: canRun) {
                            Task { await service.rawCommand(input) }
                        }
                        .frame(width: 74)
                    }
                    .padding(11)

                    Text(service.statusLine.isEmpty ? "Inget kommando skickat." : service.statusLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13)
                        .padding(.bottom, 11)
                }
            } label: {
                disclosureLabel("Konsol")
            }
            .tint(Palette.blue)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
        }
    }

    // MARK: Log

    private var logSection: some View {
        Card {
            DisclosureGroup(isExpanded: $showLog) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("\(transport.log.count) rader")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.muted)
                        Spacer(minLength: 8)
                        Button(copied ? "Kopierat" : "Kopiera") {
                            UIPasteboard.general.string = transport.log.suffix(300).joined(separator: "\n")
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.blue)
                        .buttonStyle(.plain)
                    }

                    if transport.log.isEmpty {
                        Text("Tom logg.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(recentLog.indices, id: \.self) { index in
                                Text(recentLog[index])
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Palette.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                disclosureLabel("Logg")
            }
            .tint(Palette.blue)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
        }
    }

    private var recentLog: [String] {
        Array(transport.log.suffix(24))
    }

    private func disclosureLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.ink)
    }
}
