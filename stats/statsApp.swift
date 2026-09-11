import SwiftUI

@main
struct statsApp: App {
    @StateObject private var monitor = SystemMonitor()

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
        } label: {
            Label(monitor.menuBarTitle, systemImage: "bolt.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(monitor: monitor)
        }
    }
}
