import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case overview
    case system
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Översikt"
        case .system: return "System"
        case .diagnostics: return "Diagnostik"
        case .settings: return "Inställningar"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var transport: OBDelevenTransport
    @EnvironmentObject var service: LevelControlService
    @EnvironmentObject var demo: DemoModel

    @State private var tab: AppTab = .overview
    @State private var showLink = false

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                AppHeader(showLink: $showLink)
                    .padding(.horizontal, 18)
                    .padding(.top, 6)

                TabSwitcher(selection: $tab)
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 18) {
                        switch tab {
                        case .overview:
                            OverviewView()
                        case .system:
                            SystemView()
                        case .diagnostics:
                            DiagnosticsView()
                        case .settings:
                            SettingsView(showLink: $showLink)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLink) {
            LinkSheet()
                .environmentObject(transport)
                .environmentObject(service)
        }
    }
}

// MARK: - Header

struct AppHeader: View {
    @EnvironmentObject var transport: OBDelevenTransport
    @EnvironmentObject var service: LevelControlService
    @EnvironmentObject var demo: DemoModel

    @Binding var showLink: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OBD Height Controller")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Palette.blue)

                    Text(service.profile.name.isEmpty ? "Min bil" : service.profile.name)
                        .font(.system(size: 32, weight: .bold))
                        .tracking(-1)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(service.profile.vehicle ?? "Luftfjädring · UDS")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                }

                Spacer(minLength: 8)

                Text(badgeText)
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.9)
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(badgeColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(badgeColor.opacity(0.45), lineWidth: 1)
                    )
            }

            Button {
                showLink = true
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                    Text(stateText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Text(rightText)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Palette.line, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
        }
    }

    private var badgeText: String {
        if demo.enabled { return "DEMO" }
        return transport.ready ? "LIVE" : "OFFLINE"
    }

    private var badgeColor: Color {
        if demo.enabled { return Palette.amber }
        return transport.ready ? Palette.green : Palette.amber
    }

    private var dotColor: Color {
        if demo.enabled { return Palette.amber }
        return transport.ready ? Palette.green : Palette.amber
    }

    private var stateText: String {
        if demo.enabled { return "Demoläge" }
        if transport.ready { return "Ansluten" }
        return transport.statusText == "scanning" ? "Söker adapter …" : "Ej ansluten"
    }

    private var rightText: String {
        if demo.enabled { return "Simulering · ingen BLE" }
        if let gen = transport.generation {
            return gen == 3 ? "Pro 3" : "Gen \(gen)"
        }
        return transport.ready ? transport.connectedName : "Välj adapter"
    }
}

// MARK: - Tabs

struct TabSwitcher: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selection == tab ? Palette.ink : Palette.muted)
                        .background(selection == tab ? Palette.tabActive : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Palette.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Palette.line, lineWidth: 1)
        )
    }
}

// MARK: - Connection sheet

struct LinkSheet: View {
    @EnvironmentObject var transport: OBDelevenTransport
    @EnvironmentObject var service: LevelControlService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        ValueRow(title: "Status", value: transport.statusText)
                        HairLine()
                        ValueRow(title: "Generation", value: generationText)
                        HairLine()
                        ValueRow(title: "Adapter", value: transport.ready ? transport.connectedName : "—")
                        HairLine()
                        HStack(spacing: 8) {
                            ActionButton(title: transport.ready ? "Koppla från" : "Skanna") {
                                if transport.ready { transport.disconnect() } else { transport.startScan() }
                            }
                            ActionButton(title: "Öppna styrenhet",
                                         enabled: transport.ready && !service.busy) {
                                Task { await service.connectECU() }
                            }
                        }
                        .padding(11)
                    }

                    if !transport.ready {
                        VStack(spacing: 8) {
                            SectionHeading(title: "Hittade adaptrar", trailing: "\(transport.devices.count)")
                            Card {
                                if transport.devices.isEmpty {
                                    Text("Inga adaptrar ännu. Sätt i adaptern i OBD-uttaget och tryck Skanna.")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Palette.muted)
                                        .padding(13)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    ForEach(transport.devices) { device in
                                        if device.id != transport.devices.first?.id { HairLine() }
                                        Button {
                                            transport.connect(device.id)
                                        } label: {
                                            HStack(spacing: 8) {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(device.name)
                                                        .font(.system(size: 14, weight: .semibold))
                                                        .foregroundStyle(Palette.ink)
                                                    Text(device.id.uuidString)
                                                        .font(.system(size: 9, design: .monospaced))
                                                        .foregroundStyle(Palette.muted)
                                                }
                                                Spacer(minLength: 8)
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(Palette.muted)
                                            }
                                            .padding(.horizontal, 13)
                                            .padding(.vertical, 11)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    Card {
                        ValueRow(title: "TX", value: String(format: "%08X", service.profile.txId))
                        HairLine()
                        ValueRow(title: "RX", value: String(format: "%08X", service.profile.rxId))
                        HairLine()
                        Text(service.statusLine.isEmpty ? "Ingen aktivitet." : service.statusLine)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(18)
            }
            .background(Palette.bg.ignoresSafeArea())
            .navigationTitle("Anslutning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Klar") { dismiss() }
                        .foregroundStyle(Palette.blue)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var generationText: String {
        guard let gen = transport.generation else { return transport.ready ? "—" : "Ej ansluten" }
        switch gen {
        case 3: return "3 · Pro 3"
        case 2: return "2 · BLE"
        case 1: return "1 · Classic SPP"
        default: return "\(gen)"
        }
    }
}
