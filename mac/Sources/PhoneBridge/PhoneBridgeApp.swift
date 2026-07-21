import SwiftUI

@main
struct PhoneBridgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra("PhoneBridge", systemImage:
                        state.mirroring ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3.slash") {
            Text(state.statusLine)
            Divider()
            Toggle("Mirroring", isOn: $state.mirroring)
            Button("Recent notifications") { state.showHistoryWindow() }
            Button("Show pairing QR") { state.showQRWindow() }
            if state.isPaired {
                Button("Unpair phone") { state.unpair() }
            }
            Button(state.startsAtLogin ? "Disable start at login" : "Start at login") {
                state.toggleLoginItem()
            }
            Divider()
            Button("Quit PhoneBridge") { NSApplication.shared.terminate(nil) }
        }
    }
}
