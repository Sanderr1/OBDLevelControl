import SwiftUI

struct ContentView: View {
    @EnvironmentObject var transport: OBDelevenTransport
    @EnvironmentObject var service: LevelControlService

    var body: some View {
        TabView {
            ConnectView()
                .tabItem { Label("Link", systemImage: "dot.radiowaves.left.and.right") }
            HeightsView()
                .tabItem { Label("Heights", systemImage: "arrow.up.and.down") }
            ActionsView()
                .tabItem { Label("Actions", systemImage: "wrench.and.screwdriver") }
            ConfigView()
                .tabItem { Label("Config", systemImage: "slider.horizontal.3") }
            ConsoleView()
                .tabItem { Label("Console", systemImage: "terminal") }
        }
    }
}

// MARK: - Link

struct ConnectView: View {
    @EnvironmentObject var transport: OBDelevenTransport
    @EnvironmentObject var service: LevelControlService

    var body: some View {
        NavigationStack {
            List {
                Section("Adapter") {
                    HStack {
                        Text(transport.statusText)
                        Spacer()
                        Circle()
                            .fill(transport.ready ? .green : .orange)
                            .frame(width: 10, height: 10)
                    }
                    if transport.ready {
                        Button("Disconnect", role: .destructive) { transport.disconnect() }
                    } else {
                        Button("Scan") { transport.startScan() }
                    }
                }

                if !transport.ready {
                    Section("Found") {
                        if transport.devices.isEmpty {
                            Text("No adapters yet").foregroundStyle(.secondary)
                        }
                        ForEach(transport.devices) { device in
                            Button {
                                transport.connect(device.id)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text(device.id.uuidString)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Section("ECU") {
                        LabeledContent("TX", value: String(format: "%08X", service.profile.txId))
                        LabeledContent("RX", value: String(format: "%08X", service.profile.rxId))
                        Button("Open ECU") {
                            Task { await service.connectECU() }
                        }
                        .disabled(service.busy)
                    }
                }

                Section("Status") {
                    Text(service.statusLine).font(.callout)
                }
            }
            .navigationTitle("Link")
        }
    }
}

// MARK: - Heights

struct HeightsView: View {
    @EnvironmentObject var service: LevelControlService
    @State private var autoRefresh = false
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section("Live heights") {
                    ForEach(service.readings) { reading in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reading.name)
                                Text(String(format: "DID %04X", reading.did))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(reading.value.map { String(format: "%.1f", $0) } ?? "—")
                                    .font(.title3.monospacedDigit())
                                Text(reading.raw)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Auto refresh (2 s)", isOn: $autoRefresh)
                    Button("Read now") {
                        Task { await service.readHeights() }
                    }
                    .disabled(service.busy)
                }

                Section("Status") {
                    Text(service.statusLine).font(.callout)
                }
            }
            .navigationTitle("Heights")
            .onReceive(ticker) { _ in
                guard autoRefresh, !service.busy else { return }
                Task { await service.readHeights() }
            }
            .task {
                if service.readings.isEmpty {
                    await service.readHeights()
                }
            }
        }
    }
}

// MARK: - Actions

struct ActionsView: View {
    @EnvironmentObject var service: LevelControlService
    @State private var pending: RoutineAction?

    var body: some View {
        NavigationStack {
            List {
                Section("Routines") {
                    ForEach(service.profile.actions) { action in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.name)
                                Text(action.rid == 0
                                     ? "no routine id"
                                     : String(format: "RID %04X", action.rid))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Run") {
                                if action.confirm { pending = action }
                                else { Task { await service.runAction(action) } }
                            }
                            .buttonStyle(.bordered)
                            .disabled(service.busy || action.rid == 0)
                        }
                    }
                }

                Section("Stop") {
                    ForEach(service.profile.actions.filter { $0.rid != 0 }) { action in
                        Button("Stop \(action.name)") {
                            Task { await service.stopAction(action) }
                        }
                        .disabled(service.busy)
                    }
                }

                Section("Status") {
                    Text(service.statusLine).font(.callout)
                }
            }
            .navigationTitle("Actions")
            .confirmationDialog("Run \(pending?.name ?? "")?",
                                isPresented: Binding(get: { pending != nil },
                                                     set: { if !$0 { pending = nil } })) {
                Button("Run", role: .destructive) {
                    if let action = pending {
                        Task { await service.runAction(action) }
                    }
                    pending = nil
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text("The car will move. Keep clear of the wheel arches.")
            }
        }
    }
}

// MARK: - Config

struct ConfigView: View {
    @EnvironmentObject var service: LevelControlService
    @State private var txText = ""
    @State private var rxText = ""
    @State private var scanStart = "F180"
    @State private var scanCount = "16"
    @State private var routineStart = "0000"
    @State private var routineCount = "64"

    var body: some View {
        NavigationStack {
            Form {
                Section("CAN ids") {
                    TextField("TX", text: $txText)
                        .textInputAutocapitalization(.characters)
                    TextField("RX", text: $rxText)
                        .textInputAutocapitalization(.characters)
                    Button("Apply") {
                        if let tx = UInt32(txText, radix: 16) { service.profile.txId = tx }
                        if let rx = UInt32(rxText, radix: 16) { service.profile.rxId = rx }
                    }
                }

                Section("Height channels") {
                    ForEach($service.profile.channels) { $channel in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("Name", text: $channel.name)
                                TextField("DID", value: $channel.did, format: .number)
                                    .keyboardType(.asciiCapable)
                                    .frame(width: 70)
                            }
                            HStack(spacing: 12) {
                                Stepper("len \(channel.length)", value: $channel.length, in: 1...4)
                                TextField("scale", value: $channel.scale, format: .number)
                                    .keyboardType(.decimalPad)
                                Toggle("signed", isOn: $channel.signed)
                                    .labelsHidden()
                            }
                            .font(.caption)
                        }
                    }
                }

                Section("Routine ids") {
                    ForEach($service.profile.actions) { $action in
                        HStack {
                            TextField("Name", text: $action.name)
                            TextField("RID", value: $action.rid, format: .number)
                                .frame(width: 80)
                        }
                    }
                }

                Section("Scan DIDs") {
                    HStack {
                        TextField("start", text: $scanStart)
                        TextField("count", text: $scanCount)
                            .frame(width: 70)
                        Button("Go") {
                            guard let start = UInt16(scanStart, radix: 16),
                                  let count = Int(scanCount) else { return }
                            Task { await service.scanDIDs(from: start, count: count) }
                        }
                        .disabled(service.busy)
                    }
                    ForEach(service.discoveredDIDs, id: \.self) { line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }

                Section("Scan routines (31 03)") {
                    HStack {
                        TextField("start", text: $routineStart)
                        TextField("count", text: $routineCount)
                            .frame(width: 70)
                        Button("Go") {
                            guard let start = UInt16(routineStart, radix: 16),
                                  let count = Int(routineCount) else { return }
                            Task { await service.scanRoutines(from: start, count: count) }
                        }
                        .disabled(service.busy)
                    }
                    ForEach(service.discoveredRoutines, id: \.self) { line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }

                Section("Reset") {
                    Button("Restore defaults", role: .destructive) {
                        service.profile = .blank
                    }
                }
            }
            .navigationTitle("Config")
            .onAppear {
                txText = String(format: "%08X", service.profile.txId)
                rxText = String(format: "%08X", service.profile.rxId)
            }
        }
    }
}

// MARK: - Console

struct ConsoleView: View {
    @EnvironmentObject var transport: OBDelevenTransport
    @EnvironmentObject var service: LevelControlService
    @State private var input = "22 F1 90"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("22 F1 90", text: $input)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button("Send") {
                        Task { await service.rawCommand(input) }
                    }
                    .disabled(service.busy)
                }
                .padding()

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(transport.log.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .onChange(of: transport.log.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Console")
            .overlay(alignment: .bottom) {
                Text(service.statusLine)
                    .font(.caption)
                    .padding(6)
                    .background(.thinMaterial)
            }
        }
    }
}
