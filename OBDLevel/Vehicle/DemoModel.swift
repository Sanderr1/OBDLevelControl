import Foundation

/// Simulated values and controls, ported from obd-height-controller.html.
/// Nothing here talks to the adapter; the demo is only active while `enabled` is true.
final class DemoModel: ObservableObject {

    static let idleVent = "Stäng av nivåregleringen för att prova luftning."
    static let baseHeights: [WheelSlot: Double] = [
        .frontLeft: 385,
        .frontRight: 388,
        .rearLeft: 392,
        .rearRight: 390
    ]

    @Published var enabled = false
    @Published var showValues = true
    @Published var levelOn = true
    @Published var activeVent: VentTarget?
    @Published var activeReservoir: ActionRole?
    @Published var pressureTenths = 82
    @Published var temperature = 36
    @Published var batteryTenths = 124
    @Published var compressorRunning = false
    @Published var ventStatus = DemoModel.idleVent
    @Published var reservoirStatus = "Välj fyllning eller luftning."
    @Published var settingsStatus = "Återställ höjder, nivåreglering, behållartryck, temperatur och visning."

    private var offsetFront: Double = 0
    private var offsetRear: Double = 0
    private var ventTask: Task<Void, Never>?
    private var reservoirTask: Task<Void, Never>?

    // MARK: Readings

    func height(_ slot: WheelSlot) -> Double {
        (Self.baseHeights[slot] ?? 0) + (slot.axle == .front ? offsetFront : offsetRear)
    }

    var pressure: Double { Double(pressureTenths) / 10 }
    var battery: Double { Double(batteryTenths) / 10 }

    // MARK: Mode

    func setEnabled(_ on: Bool) {
        enabled = on
        if on { reset() }
    }

    // MARK: Level control

    func setLevel(_ on: Bool) {
        levelOn = on
        cancelVent()
        offsetFront = 0
        offsetRear = 0
        if on {
            ventStatus = "Nivåreglering på. Höjderna återställdes."
        } else {
            ventStatus = "Nivåreglering av. Välj fram, bak eller båda."
        }
    }

    // MARK: Venting

    func vent(_ target: VentTarget) {
        guard !levelOn, activeVent == nil else { return }
        ventTask?.cancel()
        activeVent = target
        ventTask = Task { @MainActor in
            for axle in target.axles {
                if Task.isCancelled { return }
                self.ventStatus = "Simulerar luftning \(axle.title) …"
                try? await Task.sleep(nanoseconds: 650_000_000)
                if Task.isCancelled { return }
                switch axle {
                case .front:
                    self.offsetFront = max(self.offsetFront - 10, -40)
                case .rear:
                    self.offsetRear = max(self.offsetRear - 10, -40)
                }
            }
            if Task.isCancelled { return }
            let done = target == .both ? "fram, sedan bak" : target.axles[0].title
            self.activeVent = nil
            self.ventStatus = "Simulerad luftning klar \(done)."
        }
    }

    // MARK: Raise / lower

    func lift(_ axle: Axle, up: Bool) {
        guard activeVent == nil else { return }
        let step: Double = up ? 10 : -10
        switch axle {
        case .front: offsetFront = min(max(offsetFront + step, -40), 40)
        case .rear: offsetRear = min(max(offsetRear + step, -40), 40)
        }
        ventStatus = up ? "Höjer \(axle.title) i demot." : "Sänker \(axle.title) i demot."
    }

    // MARK: One-tap slam / normal

    /// Same order as the real sequence: level control off, front axle, rear axle.
    func slam() {
        guard activeVent == nil else { return }
        ventTask?.cancel()
        levelOn = false
        activeVent = .both
        ventStatus = "Slam: nivåreglering av …"
        ventTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            self.ventStatus = "Slam: ventilerar fram …"
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            self.offsetFront = max(self.offsetFront - 30, -40)
            self.ventStatus = "Slam: ventilerar bak …"
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            self.offsetRear = max(self.offsetRear - 30, -40)
            self.activeVent = nil
            self.ventStatus = "Slam klar i demot. Tryck Normal för att höja tillbaka."
        }
    }

    /// Turns level control back on and settles at the base heights.
    func normalLevel() {
        cancelVent()
        levelOn = true
        ventStatus = "Normal: nivåreglering på, höjer tillbaka …"
        ventTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }
            self.offsetFront = 0
            self.offsetRear = 0
            self.ventStatus = "Normalhöjd återställd i demot."
        }
    }

    // MARK: Reservoir

    func reservoir(_ action: ActionRole) {
        guard activeReservoir == nil else { return }
        let filling = action == .reservoirFill
        let limit = filling ? 105 : 0
        if pressureTenths == limit {
            reservoirStatus = filling ? "Behållaren är full i demot." : "Behållaren är tom i demot."
            return
        }

        let target = filling ? min(pressureTenths + 12, limit) : max(pressureTenths - 12, limit)
        activeReservoir = action
        compressorRunning = filling
        reservoirStatus = filling ? "Fyller behållaren i demot …" : "Luftar behållaren i demot …"

        reservoirTask?.cancel()
        reservoirTask = Task { @MainActor in
            while true {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }

                if filling {
                    self.pressureTenths = min(self.pressureTenths + 4, target)
                    self.temperature = min(self.temperature + 1, 65)
                    self.batteryTenths = max(self.batteryTenths - 1, 118)
                } else {
                    self.pressureTenths = max(self.pressureTenths - 4, target)
                }

                if self.pressureTenths == target {
                    self.activeReservoir = nil
                    self.compressorRunning = false
                    self.reservoirStatus = filling ? "Simulerad fyllning klar." : "Simulerad luftning klar."
                    return
                }
            }
        }
    }

    // MARK: Reset

    func reset() {
        cancelVent()
        cancelReservoir()
        offsetFront = 0
        offsetRear = 0
        levelOn = true
        showValues = true
        pressureTenths = 82
        temperature = 36
        batteryTenths = 124
        ventStatus = Self.idleVent
        reservoirStatus = "Välj fyllning eller luftning."
        settingsStatus = "Demot är återställt."
    }

    private func cancelVent() {
        ventTask?.cancel()
        ventTask = nil
        activeVent = nil
    }

    private func cancelReservoir() {
        reservoirTask?.cancel()
        reservoirTask = nil
        activeReservoir = nil
        compressorRunning = false
    }
}
