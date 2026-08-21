import SwiftUI

@main
struct SnoreAlertApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var monitor: SnoreAudioMonitor

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _monitor = StateObject(wrappedValue: SnoreAudioMonitor(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(monitor)
        }
    }
}

