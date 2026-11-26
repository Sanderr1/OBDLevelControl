import SwiftUI

struct SystemView: View {
    @EnvironmentObject var service: LevelControlService
    @EnvironmentObject var demo: DemoModel

    @State private var showHidden = false

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var liveReady: Bool { service.ecuOpen }

    var body: some View {
        VStack(spacing: 18) {
            batterySection
            systemSection
            reservoirSection
        }
        .onAppear {
            guard !demo.enabled, service.ecuOpen, !service.busy else { return }
            Task { await service.readVisibleChannels() }
        }
    }

    // MARK: Battery

    private var batterySection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Batteri",
                           trailing: demo.enabled ? "Simulerat" : (liveReady ? "Live" : "Offline"))

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
            SectionHeading(title: "Luftsystem",
                           trailing: demo.enabled ? "Simulerade värden" : (liveReady ? "Live" : "Offline"))

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

            if !demo.enabled {
                ActionButton(title: "Läs luftvärden", enabled: !service.busy) {
                    Task { await service.readVisibleChannels() }
                }
            }

            if !demo.enabled && !service.hiddenChannels.isEmpty {
                hiddenSection
            }
        }
    }

    /// Every extra value stays in the profile but is neither polled nor shown.
    /// This is the way back: tap Visa, the value is read once and returns to the
    /// grid above.
    private var hiddenSection: some View {
        Card {
            DisclosureGroup(isExpanded: $showHidden) {
                VStack(spacing: 0) {
                    ForEach(service.hiddenChannels) { channel in
                        HairLine()
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(channel.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                                Text(String(format: "DID %04X · %d byte", channel.did,
                                            channel.length))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Palette.muted)
                            }
                            Spacer(minLength: 8)
                            Button("Visa") {
                                Task { await service.showChannel(channel.id) }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.blue)
                            .disabled(service.busy)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                    Text("Dolda värden")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Text("\(service.hiddenChannels.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
            }
            .tint(Palette.blue)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
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
        // Status/count channels have no unit and are integers; pressure and
        // temperature keep one decimal.
        return formatValue(service.readings[channelIndex].value,
                           decimals: channel.unit == nil ? 0 : 1)
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
        return liveReady && !service.busy && service.hasRoutine(role)
    }

    private func trigger(_ role: ActionRole) {
        if demo.enabled {
            demo.reservoir(role)
        } else {
            Task { await service.reservoir(role) }
        }
    }
}
