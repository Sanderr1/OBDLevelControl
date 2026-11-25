import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var transport: OBDelevenTransport
    @EnvironmentObject var service: LevelControlService
    @EnvironmentObject var demo: DemoModel

    @State private var autoRefresh = false
    @State private var pendingVent: VentTarget?
    @State private var showMore = false

    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(spacing: 18) {
            rideSection
            heightsSection
            moreSection
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

    // MARK: Raise / lower - the one thing this app is for

    private var rideSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Höj & sänk", trailing: demo.enabled ? "Simulering" : "Live")

            Card {
                HStack(spacing: 8) {
                    ActionButton(title: "Höj", enabled: bothEnabled(up: true)) {
                        moveBoth(up: true)
                    }
                    ActionButton(title: "Sänk", enabled: bothEnabled(up: false)) {
                        moveBoth(up: false)
                    }
                }
                .padding(11)

                if service.canStop {
                    HairLine()
                    HStack(spacing: 8) {
                        ActionButton(title: "Stoppa", running: true) {
                            service.requestStop()
                        }
                    }
                    .padding(11)
                }

                HairLine()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Båda axlarna")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(rideStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            if !demo.enabled {
                Text("Höj går till högläge, Sänk tillbaka till normalnivå.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }
        }
    }

    private func bothEnabled(up: Bool) -> Bool {
        if demo.enabled { return demo.activeVent == nil && demo.activeReservoir == nil }
        let role: ActionRole = up ? .raiseHigh : .lowerNormal
        if service.hasRoutine(role) { return !service.busy }
        let roles: [ActionRole] = up ? [.raiseFront, .raiseRear] : [.lowerFront, .lowerRear]
        return !service.busy && roles.allSatisfy { service.hasRoutine($0) }
    }

    private func moveBoth(up: Bool) {
        if demo.enabled {
            demo.lift(.front, up: up)
            demo.lift(.rear, up: up)
        } else {
            Task { await service.moveBoth(up: up) }
        }
    }

    private var rideStatus: String {
        if demo.enabled { return demo.ventStatus }
        return service.statusLine.isEmpty ? "Redo." : service.statusLine
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

    // MARK: Everything else, folded away

    private var moreSection: some View {
        Card {
            DisclosureGroup(isExpanded: $showMore) {
                VStack(spacing: 0) {
                    HairLine()

                    ForEach([Axle.front, Axle.rear], id: \.self) { axle in
                        if axle == .rear { HairLine() }
                        HStack(spacing: 8) {
                            Text(axle.heading)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                                .frame(width: 46, alignment: .leading)

                            ActionButton(title: "Höj", enabled: rideEnabled(axle, up: true)) {
                                ride(axle, up: true)
                            }
                            ActionButton(title: "Sänk", enabled: rideEnabled(axle, up: false)) {
                                ride(axle, up: false)
                            }
                        }
                        .padding(11)
                    }

                    HairLine()
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
                    .padding(11)

                    HairLine()
                    Text(controlStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.blue)
                    Text("Fler kontroller")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Text(levelOn ? "Nivåreglering på" : "Axel för axel · luftning")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
            }
            .tint(Palette.blue)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
        }
    }

    private func rideRole(_ axle: Axle, up: Bool) -> ActionRole {
        switch (axle, up) {
        case (.front, true): return .raiseFront
        case (.front, false): return .lowerFront
        case (.rear, true): return .raiseRear
        case (.rear, false): return .lowerRear
        }
    }

    private func rideEnabled(_ axle: Axle, up: Bool) -> Bool {
        if demo.enabled { return demo.activeVent == nil && demo.activeReservoir == nil }
        return !service.busy && service.hasRoutine(rideRole(axle, up: up))
    }

    private func ride(_ axle: Axle, up: Bool) {
        if demo.enabled {
            demo.lift(axle, up: up)
        } else if let action = service.action(for: rideRole(axle, up: up)) {
            Task { await service.runAction(action) }
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
