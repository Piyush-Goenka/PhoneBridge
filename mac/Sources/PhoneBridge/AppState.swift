import AppKit
import SwiftUI
import ServiceManagement
import PhoneBridgeCore

@MainActor
final class AppState: ObservableObject {
    @Published var mirroring = true {
        didSet { gate.enabled = mirroring }
    }
    @Published var statusLine = "Starting"
    @Published var startsAtLogin = SMAppService.mainApp.status == .enabled

    private let notifier = Notifier()
    private let gate: GatedSink
    private let server = BridgeServer()
    private let bonjour = BonjourAdvertiser()
    private var pairing: PairingInfo?
    private var qrWindow: NSWindow?

    init() {
        gate = GatedSink(wrapping: notifier)
        do {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PhoneBridge")
            let info = try Pairing.ensure(directory: dir)
            pairing = info
            let icons = try DiskIconStore(directory: dir.appendingPathComponent("icons"))
            let handler = RequestHandler(token: info.token, icons: icons, sink: gate)
            try server.start(certPath: info.certPath, keyPath: info.keyPath, handler: handler)
            bonjour.publish(port: server.port)
            notifier.activate(onDenied: { [weak self] in
                self?.statusLine = "Notifications blocked: enable PhoneBridge in System Settings, Notifications"
            })
            statusLine = "Listening on port \(server.port)"
        } catch {
            statusLine = "Failed to start: \(error.localizedDescription)"
        }
    }

    func showQRWindow() {
        guard let pairing else { return }
        if let existing = qrWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let payload = Pairing.qrPayload(info: pairing, port: server.port)
        let image = QRRenderer.image(from: payload, size: 300)

        let content = VStack(spacing: 12) {
            Text("Scan with the PhoneBridge Android app")
                .font(.headline)
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 300, height: 300)
            Text("Port \(server.port)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Pair your phone"
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        qrWindow = window
    }

    func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Registration fails when running unbundled; harmless.
        }
        startsAtLogin = SMAppService.mainApp.status == .enabled
    }
}
