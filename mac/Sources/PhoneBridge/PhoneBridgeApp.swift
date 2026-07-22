import SwiftUI

@main
struct PhoneBridgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra(
            "PhoneBridge",
            systemImage: state.mirroring
                ? "iphone.gen3.radiowaves.left.and.right"
                : "iphone.gen3.slash"
        ) {
            Label(state.statusLine, systemImage: state.statusSymbolName)

            Divider()

            Toggle(isOn: $state.mirroring) {
                Label(
                    "Mirror Notifications",
                    systemImage: state.mirroring ? "bell.badge" : "bell.slash")
            }
            Button {
                state.showHistoryWindow()
            } label: {
                Label("Notification History…", systemImage: "clock.arrow.circlepath")
            }

            Divider()

            Button {
                state.showQRWindow()
            } label: {
                Label(
                    state.isPaired ? "Show Pairing QR…" : "Pair a Phone…",
                    systemImage: "qrcode.viewfinder")
            }
            if state.isPaired {
                Button(role: .destructive) {
                    state.unpair()
                } label: {
                    Label("Unpair Phone…", systemImage: "iphone.gen3.slash")
                }
            }

            Divider()

            Toggle(isOn: Binding(
                get: { state.startsAtLogin },
                set: { _ in state.toggleLoginItem() }
            )) {
                Label("Start at Login", systemImage: "power")
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit PhoneBridge", systemImage: "xmark.circle")
            }
            .keyboardShortcut("q")
        }
    }
}
