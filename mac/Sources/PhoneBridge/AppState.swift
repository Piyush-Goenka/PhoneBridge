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

    private let notificationCards = NotificationCardController()
    private let callPanel = CallPanelController()
    private let gate: GatedSink
    private let callRegistry = CallActionRegistry()
    private let server = BridgeServer()
    private let bonjour = BonjourAdvertiser()
    private let history: NotificationHistory
    let historyModel = HistoryModel()
    private var iconStore: DiskIconStore?
    private var pairing: PairingInfo?
    private var qrWindow: NSWindow?
    private var historyWindow: NSWindow?

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneBridge")
        history = NotificationHistory(fileURL: dir.appendingPathComponent("history.json"))
        gate = GatedSink(
            wrapping: HistorySink(wrapping: notificationCards, history: history),
            calls: callPanel)
        historyModel.entries = history.entries
        history.onChange = { [historyModel] entries in
            DispatchQueue.main.async { historyModel.entries = entries }
        }
        do {
            let info = try Pairing.ensure(directory: dir)
            pairing = info
            let icons = try DiskIconStore(directory: dir.appendingPathComponent("icons"))
            iconStore = icons
            let handler = RequestHandler(
                token: info.token, icons: icons, sink: gate,
                calls: callRegistry, callSink: gate)
            callPanel.onAction = { [callRegistry] key, action in
                callRegistry.fulfill(key: key, action: action)
            }
            try server.start(certPath: info.certPath, keyPath: info.keyPath, handler: handler)
            bonjour.publish(port: server.port)
            statusLine = "Listening on port \(server.port)"
        } catch {
            statusLine = "Failed to start: \(error.localizedDescription)"
        }
    }

    func showHistoryWindow() {
        if let existing = historyWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = HistoryView(
            model: historyModel,
            iconFor: { [weak self] hash in
                guard !hash.isEmpty, let path = self?.iconStore?.path(hash) else { return nil }
                return NSImage(contentsOf: path)
            },
            onClear: { [weak self] in self?.history.clear() })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "PhoneBridge history"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = window
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
