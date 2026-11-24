import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var transport: OBDelevenTransport
    @EnvironmentObject var service: LevelControlService
    @EnvironmentObject var demo: DemoModel

    @Binding var showLink: Bool

    @State private var didStart = "F180"
    @State private var didCount = "32"
    @State private var ridStart = "0000"
    @State private var ridCount = "64"
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 18) {
            vehicleSection
            connectionSection
            mappingSection
            channelSection
            routineSection
            scanSection
            demoSection
            resetSection
        }
        .confirmationDialog("Återställ profilen?",
                            isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("Återställ", role: .destructive) {
                service.resetProfile()
            }
            Button("Avbryt", role: .cancel) { }
        } message: {
            Text("CAN-id, kanaler och rutiner sätts tillbaka till standardvärden. Höjdvärden rensas.")
        }
    }

    // MARK: Vehicle

    private var vehicleSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Bil", trailing: nil)
            Card {
                HStack(spacing: 8) {
                    FieldBox {
                        VStack(alignment: .leading, spacing: 2) {
                            FieldCaption(text: "NAMN")
                            TextField("Min bil", text: $service.profile.name)
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.ink)
                                .textFieldStyle(.plain)
                        }
                    }
                    FieldBox {
                        VStack(alignment: .leading, spacing: 2) {
                            FieldCaption(text: "FORDONSINFO")
                            TextField("Årsmodell · motor · fjädring", text: vehicleBinding)
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.ink)
                                .textFieldStyle(.plain)
                        }
                    }
                }
                .padding(11)
            }
        }
    }

    private var vehicleBinding: Binding<String> {
        Binding(
            get: { service.profile.vehicle ?? "" },
            set: { service.profile.vehicle = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: Connection

    private var connectionSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Anslutning", trailing: nil)
            Card {
                HStack(spacing: 8) {
                    HexField(label: "TX", value: $service.profile.txId, digits: 8)
                    HexField(label: "RX", value: $service.profile.rxId, digits: 8)
                }
                .padding(11)

                HairLine()

                HStack(spacing: 8) {
                    ActionButton(title: "Anslut adapter") {
                        showLink = true
                    }
                    ActionButton(title: "Öppna styrenhet",
                                 enabled: transport.ready && !service.busy) {
                        Task { await service.connectECU() }
                    }
                }
                .padding(11)

                HairLine()

                ValueRow(title: "Adapter",
                         value: transport.ready ? transport.connectedName : "Ej ansluten",
                         valueColor: transport.ready ? Palette.green : Palette.muted)
            }
        }
    }

    // MARK: Role mapping

    private var mappingSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Funktionsmappning", trailing: "RID → knapp")
            Card {
                ForEach(ActionRole.allCases) { role in
                    if role != ActionRole.allCases.first { HairLine() }
                    HStack(spacing: 8) {
                        Text(role.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        Spacer(minLength: 8)
                        Picker("", selection: roleBinding(role)) {
                            Text("—").tag(UUID?.none)
                            ForEach(service.profile.actions) { action in
                                Text(action.name).tag(Optional(action.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(Palette.blue)
                    }
                    .padding(.horizontal, 13)
                    .frame(minHeight: 48)
                }
            }
        }
    }

    private func roleBinding(_ role: ActionRole) -> Binding<UUID?> {
        Binding(
            get: { service.profile.actions.first { $0.role == role }?.id },
            set: { service.assign(role, to: $0) }
        )
    }

    // MARK: Channels

    private var channelSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Höjdkanaler", trailing: "\(service.profile.channels.count) st")
            Card {
                ForEach($service.profile.channels) { $channel in
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            FieldBox {
                                VStack(alignment: .leading, spacing: 2) {
                                    FieldCaption(text: "NAMN")
                                    TextField("Kanal", text: $channel.name)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Palette.ink)
                                        .textFieldStyle(.plain)
                                }
                            }

                            HexField(label: "DID",
                                     value: $channel.did.adapted(get: { UInt32($0) },
                                                                 set: { UInt16(truncatingIfNeeded: $0) }),
                                     digits: 4)
                                .frame(width: 92)

                            Button {
                                service.removeChannel(channel.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.muted)
                                    .frame(width: 26, height: 30)
                            }
                            .buttonStyle(.plain)
                        }

                        HStack(spacing: 8) {
                            FieldBox {
                                VStack(alignment: .leading, spacing: 2) {
                                    FieldCaption(text: "BYTE")
                                    Picker("", selection: $channel.length) {
                                        ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(Palette.ink)
                                    .font(.system(size: 13))
                                }
                            }

                            FieldBox {
                                VStack(alignment: .leading, spacing: 2) {
                                    FieldCaption(text: "SKALA")
                                    TextField("1", value: $channel.scale, format: .number)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(Palette.ink)
                                        .textFieldStyle(.plain)
                                        .keyboardType(.decimalPad)
                                }
                            }

                            FieldBox {
                                VStack(alignment: .leading, spacing: 2) {
                                    FieldCaption(text: "ENHET")
                                    TextField("mm", text: $channel.unit.adapted(get: { $0 ?? "" },
                                                                                 set: { $0.isEmpty ? nil : $0 }))
                                        .font(.system(size: 13))
                                        .foregroundStyle(Palette.ink)
                                        .textFieldStyle(.plain)
                                }
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                FieldCaption(text: "TECKEN")
                                Toggle("", isOn: $channel.signed)
                                    .labelsHidden()
                                    .tint(Palette.switchOn)
                            }
                        }
                    }
                    .padding(11)
                    .overlay(alignment: .top) {
                        if channel.id != service.profile.channels.first?.id {
                            HairLine()
                        }
                    }
                }

                HairLine()
                HStack(spacing: 8) {
                    ActionButton(title: "Lägg till kanal") {
                        service.addChannel()
                    }
                }
                .padding(11)
            }
        }
    }

    // MARK: Routines

    private var routineSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Rutiner", trailing: "31 01 / 02 / 03")
            Card {
                ForEach($service.profile.actions) { $action in
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            FieldBox {
                                VStack(alignment: .leading, spacing: 2) {
                                    FieldCaption(text: "NAMN")
                                    TextField("Rutin", text: $action.name)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Palette.ink)
                                        .textFieldStyle(.plain)
                                }
                            }
                            HexField(label: "RID",
                                     value: $action.rid.adapted(get: { UInt32($0) },
                                                                 set: { UInt16(truncatingIfNeeded: $0) }),
                                     digits: 4)
                                .frame(width: 92)
                        }

                        HStack(spacing: 8) {
                            Text(action.role?.title ?? "Ingen roll")
                                .font(.system(size: 11))
                                .foregroundStyle(action.role == nil ? Palette.amber : Palette.muted)
                            Spacer(minLength: 8)
                            ActionButton(title: "Kör",
                                         enabled: !service.busy && action.rid != 0) {
                                Task { await service.runAction(action) }
                            }
                            .frame(width: 82)
                            ActionButton(title: "Stopp",
                                         enabled: !service.busy && action.rid != 0) {
                                Task { await service.stopAction(action) }
                            }
                            .frame(width: 82)
                        }
                    }
                    .padding(11)
                    .overlay(alignment: .top) {
                        if action.id != service.profile.actions.first?.id {
                            HairLine()
                        }
                    }
                }
            }
        }
    }

    // MARK: Scanners

    private var scanSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Skanna", trailing: "Hitta okända id:n")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    FieldCaption(text: "DID — 22 <did>, från + antal")

                    HStack(spacing: 8) {
                        FieldBox {
                            VStack(alignment: .leading, spacing: 2) {
                                FieldCaption(text: "FRÅN")
                                TextField("F180", text: $didStart)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Palette.ink)
                                    .textFieldStyle(.plain)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                            }
                        }
                        FieldBox {
                            VStack(alignment: .leading, spacing: 2) {
                                FieldCaption(text: "ANTAL")
                                TextField("32", text: $didCount)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Palette.ink)
                                    .textFieldStyle(.plain)
                                    .keyboardType(.numberPad)
                            }
                        }
                        .frame(width: 76)
                        ActionButton(title: "Go", enabled: scanEnabled) {
                            guard let start = UInt16(didStart, radix: 16),
                                  let count = Int(didCount) else { return }
                            Task { await service.scanDIDs(from: start, count: count) }
                        }
                        .frame(width: 60)
                    }

                    if !service.discoveredDIDs.isEmpty {
                        ForEach(service.discoveredDIDs, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                }
                .padding(11)

                HairLine()

                VStack(alignment: .leading, spacing: 8) {
                    FieldCaption(text: "RUTIN — 31 03 <rid>, från + antal")

                    HStack(spacing: 8) {
                        FieldBox {
                            VStack(alignment: .leading, spacing: 2) {
                                FieldCaption(text: "FRÅN")
                                TextField("0000", text: $ridStart)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Palette.ink)
                                    .textFieldStyle(.plain)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                            }
                        }
                        FieldBox {
                            VStack(alignment: .leading, spacing: 2) {
                                FieldCaption(text: "ANTAL")
                                TextField("64", text: $ridCount)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Palette.ink)
                                    .textFieldStyle(.plain)
                                    .keyboardType(.numberPad)
                            }
                        }
                        .frame(width: 76)
                        ActionButton(title: "Go", enabled: scanEnabled) {
                            guard let start = UInt16(ridStart, radix: 16),
                                  let count = Int(ridCount) else { return }
                            Task { await service.scanRoutines(from: start, count: count) }
                        }
                        .frame(width: 60)
                    }

                    if !service.discoveredRoutines.isEmpty {
                        ForEach(service.discoveredRoutines, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                }
                .padding(11)

                HairLine()

                Text(service.statusLine.isEmpty ? "Ingen skanning körd." : service.statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
    }

    private var scanEnabled: Bool {
        transport.ready && !service.busy
    }

    // MARK: Demo

    private var demoSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Demo", trailing: nil)
            Card {
                SwitchRow(title: "Demoläge",
                          detail: "Visar simulerade värden och skickar inga kommandon.",
                          isOn: Binding(get: { demo.enabled }, set: { demo.setEnabled($0) }))
                HairLine()
                SwitchRow(title: "Visa exempelvärden",
                          detail: "Döljer eller visar siffrorna i demon.",
                          isOn: $demo.showValues)
                HairLine()
                HStack(spacing: 8) {
                    ActionButton(title: "Återställ demot") {
                        demo.reset()
                    }
                }
                .padding(11)
                HairLine()
                Text(demo.settingsStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
    }

    // MARK: Reset

    private var resetSection: some View {
        VStack(spacing: 10) {
            SectionHeading(title: "Profil", trailing: nil)
            Card {
                HStack(spacing: 8) {
                    ActionButton(title: "Återställ profil") {
                        confirmReset = true
                    }
                }
                .padding(11)
            }
        }
    }
}
