import SwiftUI

@main
struct OBDLevelApp: App {
    @StateObject private var transport: OBDelevenTransport
    @StateObject private var service: LevelControlService
    @StateObject private var demo = DemoModel()

    init() {
        let t = OBDelevenTransport()
        _transport = StateObject(wrappedValue: t)
        _service = StateObject(wrappedValue: LevelControlService(transport: t))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(transport)
                .environmentObject(service)
                .environmentObject(demo)
        }
    }
}
