import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var transport: OBDelevenTransport
    @EnvironmentObject var service: LevelControlService
    @EnvironmentObject var demo: DemoModel

    @State private var autoRefresh = false
    @State private var pendingVent: VentTarget?

    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(spacing: 18) {
            heightsSection
            controlsSection
        }
        .onReceive(ticker) { _ in
            guard autoRefresh, !demo.enabled, transport.ready, !service.busy else { return }
            Task { await service.readHeights() }
        }
        .confirmationDialog(pendingVent.map { "\($0.title)?" } ?? "Lufta?",
                            isPresented: Binding(get: { pendingVent != nil },
                                                 set: { if !$0 { pendingVent = nil } }),
                            titleVisibility: .visible) {
            Button("Lufta nu", role: .destructive) {
                if let target = pendingVent {
                    Task { await service.vent(target) }
                }
                pendingVent = nil
            }
            Button("Avbryt", role: .cancel) { pendingVent = nil }
        } message: {
            Text("Bilen rör sig. Håll dig borta från hjulhusen och ha batteriladdaren inkopplad.")
        }
    }

    // MARK: Heights

    private var heightsSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Hjulhöjd", trailing: heightsCaption)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(WheelSlot.allCases, id: \.self) { slot in
                    WheelCard(title: slot.title,
                              text: heightText(slot),
                              unit: "mm")
                }
            }

            HStack(spacing: 8) {
                ActionButton(title: "Läs nu", enabled: canRead) {
                    Task { await service.readHeights() }
                }
                ActionButton(title: autoRefresh ? "Auto 2 s · på" : "Auto 2 s · av",
                             running: autoRefresh,
                             enabled: !demo.enabled) {
                    autoRefresh.toggle()
                }
            }
        }
    }

    private func heightText(_ slot: WheelSlot) -> String {
        if demo.enabled {
            return demo.showValues ? formatValue(demo.height(slot), decimals: 0) : "–"
        }
        return formatValue(liveValue(slot), decimals: 0)
    }

    private func liveValue(_ slot: WheelSlot) -> Double? {
        let index = slot.rawValue
        guard index < service.readings.count else { return nil }
        return service.readings[index].value
    }

    private var heightsCaption: String {
        if demo.enabled { return demo.showValues ? "Simulerade värden" : "Värden dolda" }
        return service.readings.contains { $0.value != nil } ? "Live" : "Ej avlästa"
    }

    private var canRead: Bool {
        !demo.enabled && transport.ready && !service.busy
    }

    // MARK: Controls

    private var controlsSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Fjädringskontroller", trailing: demo.enabled ? "Simulering" : "Live")

            Card {
                SwitchRow(title: "Nivåreglering",
                          detail: levelOn ? "På" : "Av",
                          isOn: Binding(get: { levelOn }, set: { setLevel($0) }))
                HairLine()
                HStack(spacing: 6) {
                    ForEach(VentTarget.allCases, id: \.self) { target in
                        ActionButton(title: target.buttonTitle,
                                     running: isVentRunning(target),
                                     enabled: ventEnabled(target)) {
                            triggerVent(target)
                        }
                    }
                }
                .padding(.horizontal, 11)
                .padding(.top, 10)
                HairLine()
                    .padding(.top, 10)
                Text(controlStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }

            if !demo.enabled {
                Text("Luftning kräver att nivåregleringen är avstängd. RID:n mappas under Inställningar → Funktionsmappning.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var levelOn: Bool {
        demo.enabled ? demo.levelOn : service.levelControlEnabled
    }

    private var controlStatus: String {
        if demo.enabled { return demo.ventStatus }
        return service.statusLine.isEmpty ? "Redo." : service.statusLine
    }

    private func setLevel(_ on: Bool) {
        if demo.enabled {
            demo.setLevel(on)
        } else {
            Task { await service.setLevelControl(on) }
        }
    }

    private func ventEnabled(_ target: VentTarget) -> Bool {
        guard !levelOn else { return false }
        if demo.enabled { return demo.activeVent == nil }
        return !service.busy && service.canVent(target)
    }

    private func isVentRunning(_ target: VentTarget) -> Bool {
        demo.enabled && demo.activeVent == target
    }

    private func triggerVent(_ target: VentTarget) {
        if demo.enabled {
            demo.vent(target)
        } else {
            pendingVent = target
        }
    }
}
