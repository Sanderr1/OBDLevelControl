import SwiftUI

struct SystemView: View {
    @EnvironmentObject var service: LevelControlService
    @EnvironmentObject var demo: DemoModel

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(spacing: 18) {
            batterySection
            systemSection
            reservoirSection
        }
    }

    // MARK: Battery

    private var batterySection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Batteri", trailing: demo.enabled ? "Simulerat" : "Live")

            Card {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(batteryText)
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(batteryColor)
                    Text("V")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: 8)
                    Text(batteryState)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(batteryColor)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)

                HairLine()

                Text(batteryDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
    }

    private var batteryValue: Double? {
        if demo.enabled { return demo.showValues ? demo.battery : nil }
        return service.batteryReading?.value
    }

    private var batteryText: String {
        formatValue(batteryValue, decimals: 1)
    }

    private var batteryColor: Color {
        guard let value = batteryValue else { return Palette.muted }
        if value >= 12.4 { return Palette.green }
        if value >= 11.8 { return Palette.amber }
        return Color(rgb: 0xFF8A8A)
    }

    private var batteryState: String {
        guard let value = batteryValue else { return "—" }
        if value >= 12.4 { return "God" }
        if value >= 11.8 { return "Låg" }
        return "Kritisk låg"
    }

    private var batteryDetail: String {
        if demo.enabled {
            return demo.compressorRunning
                ? "Simuleras sjunka medan kompressorn går."
                : "Simulerat värde. Ingen BLE-trafik."
        }
        guard let channel = service.batteryChannel else {
            return "Ingen batterikanal i profilen."
        }
        if channel.did == 0 {
            return "DID saknas. Kör Autokonfigurering eller fyll i DID under Inställningar → Höjdkanaler."
        }
        return String(format: "DID %04X · %d byte · skala %g V", channel.did, channel.length, channel.scale)
    }

    // MARK: System values

    private var systemSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Luftsystem", trailing: demo.enabled ? "Simulerade värden" : "Live")

            if service.systemChannels.isEmpty {
                Card {
                    Text("Inga systemkanaler. Lägg till t.ex. systemtryck och kompressortemperatur under Inställningar → Höjdkanaler.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(service.systemChannels) { channel in
                        WheelCard(title: channel.name,
                                  text: channelText(channel),
                                  unit: channel.unit ?? "")
                    }
                }
            }
        }
    }

    private func channelText(_ channel: HeightChannel) -> String {
        guard let channelIndex = service.profile.channels.firstIndex(where: { $0.id == channel.id }) else {
            return "–"
        }
        if demo.enabled {
            guard demo.showValues else { return "–" }
            switch service.systemChannels.firstIndex(where: { $0.id == channel.id }) {
            case 0?: return formatValue(demo.pressure, decimals: 1)
            case 1?: return "\(demo.temperature)"
            default: return "–"
            }
        }
        guard channelIndex < service.readings.count else { return "–" }
        return formatValue(service.readings[channelIndex].value, decimals: 1)
    }

    // MARK: Reservoir

    private var reservoirSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Luftbehållare", trailing: nil)

            Card {
                ValueRow(title: "Kompressor",
                         value: compressorText,
                         valueColor: demo.enabled && demo.compressorRunning ? Palette.blue : Palette.ink)
                HairLine()
                HStack(spacing: 6) {
                    ActionButton(title: "Fyll behållare",
                                 running: demo.enabled && demo.activeReservoir == .reservoirFill,
                                 enabled: reservoirEnabled(.reservoirFill)) {
                        trigger(.reservoirFill)
                    }
                    ActionButton(title: "Lufta behållare",
                                 running: demo.enabled && demo.activeReservoir == .reservoirVent,
                                 enabled: reservoirEnabled(.reservoirVent)) {
                        trigger(.reservoirVent)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.top, 10)
                HairLine()
                    .padding(.top, 10)
                Text(reservoirStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
    }

    private var compressorText: String {
        if demo.enabled { return demo.compressorRunning ? "I drift" : "I vila" }
        return "Ej avläst"
    }

    private var reservoirStatus: String {
        if demo.enabled { return demo.reservoirStatus }
        if service.hasRoutine(.reservoirFill) || service.hasRoutine(.reservoirVent) {
            return service.statusLine.isEmpty ? "Redo." : service.statusLine
        }
        return "Inga RID:n mappade för behållaren (Inställningar → Funktionsmappning)."
    }

    private func reservoirEnabled(_ role: ActionRole) -> Bool {
        if demo.enabled { return demo.activeReservoir == nil }
        return !service.busy && service.hasRoutine(role)
    }

    private func trigger(_ role: ActionRole) {
        if demo.enabled {
            demo.reservoir(role)
        } else {
            Task { await service.reservoir(role) }
        }
    }
}
