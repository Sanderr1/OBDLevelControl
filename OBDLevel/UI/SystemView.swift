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
            systemSection
            reservoirSection
        }
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
        guard let index = service.systemChannels.firstIndex(where: { $0.id == channel.id }) else {
            return "–"
        }
        if demo.enabled {
            guard demo.showValues else { return "–" }
            if index == 0 { return formatValue(demo.pressure, decimals: 1) }
            if index == 1 { return "\(demo.temperature)" }
            return "–"
        }
        let readingIndex = 4 + index
        guard readingIndex < service.readings.count else { return "–" }
        return formatValue(service.readings[readingIndex].value, decimals: 1)
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
