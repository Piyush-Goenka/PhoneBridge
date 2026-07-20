import AppKit
import Network
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
    private var pathMonitor: NWPathMonitor?
    private var lastKnownIPv4: String?
    private var enrollment: EnrollmentCoordinator?
    private let phoneCertPath: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneBridge")
        phoneCertPath = PhoneCertStore.path(directory: dir)
        // Encrypt history at rest with a Keychain-held key; fall back to
        // plaintext only if the Keychain is somehow unavailable, so history
        // still works rather than vanishing.
        let cipher: HistoryCipher = (try? KeychainHistoryCipher()) ?? PlaintextHistoryCipher()
        history = NotificationHistory(
            fileURL: dir.appendingPathComponent("history.json"), cipher: cipher)
        gate = GatedSink(
            wrapping: HistorySink(wrapping: notificationCards, history: history),
            calls: CallHistorySink(wrapping: callPanel, history: history))
        historyModel.entries = history.entries
        history.onChange = { [historyModel] entries in
            DispatchQueue.main.async { historyModel.entries = entries }
        }
        do {
            let info = try Pairing.ensure(directory: dir)
            pairing = info
            let icons = try DiskIconStore(directory: dir.appendingPathComponent("icons"))
            iconStore = icons
            // Locked at launch once a phone has enrolled; open until then so a
            // fresh install (or a migrating token-only pairing) can enroll.
            let phoneEnrolled = PhoneCertStore.loadTrustRoot(at: phoneCertPath) != nil
            let launchMode: ServerMode = phoneEnrolled ? .locked : .open
            let coordinator = EnrollmentCoordinator(
                certPath: phoneCertPath, open: launchMode == .open)
            coordinator.onEnrolled = { [weak self] in
                Task { @MainActor in self?.lockAfterEnrollment() }
            }
            enrollment = coordinator
            let handler = RequestHandler(
                token: info.token, icons: icons, sink: gate,
                calls: callRegistry, callSink: gate, enroller: coordinator)
            callPanel.onAction = { [callRegistry] key, action in
                callRegistry.fulfill(key: key, action: action)
            }
            notificationCards.onOpenHistory = { [weak self] in
                self?.showHistoryWindow()
            }
            try server.start(
                certPath: info.certPath, keyPath: info.keyPath, handler: handler,
                phoneCertPath: phoneCertPath, mode: launchMode)
            bonjour.publish(port: server.port)
            statusLine = "Listening on port \(server.port)"
        } catch {
            statusLine = "Failed to start: \(error.localizedDescription)"
        }

        lastKnownIPv4 = Pairing.primaryIPv4()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAfterNetworkEvent() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.refreshAfterNetworkEvent() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    // Lid reopen or network change can hand the Mac a new address. The
    // server socket survives (it binds 0.0.0.0); what goes stale is the
    // advertisement and the QR, so refresh exactly those.
    private func refreshAfterNetworkEvent() {
        let current = Pairing.primaryIPv4()
        guard current != lastKnownIPv4 else { return }
        lastKnownIPv4 = current
        bonjour.stop()
        bonjour.publish(port: server.port)
        if let qrWindow, qrWindow.isVisible, let pairing {
            qrWindow.contentView = NSHostingView(rootView: qrContent(info: pairing))
        }
        statusLine = "Listening on port \(server.port)"
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
        // Opening the pairing window is the physical consent step: unlock the
        // server so a new (or re-pairing) phone can enroll.
        openForPairing()
        // The payload embeds the Mac's current IP, so it is rebuilt on
        // every open; a cached first render could show a dead address.
        if let existing = qrWindow {
            existing.contentView = NSHostingView(rootView: qrContent(info: pairing))
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Pair your phone"
        window.contentView = NSHostingView(rootView: qrContent(info: pairing))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Closing the window ends the consent window: re-lock if a phone has
        // enrolled, otherwise stay open (nothing to lock to yet).
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.relockIfEnrolled() }
        }
        qrWindow = window
    }

    // Switch to open mode so /enroll is accepted. Idempotent.
    private func openForPairing() {
        enrollment?.setOpen(true)
        guard server.mode != .open else { return }
        do {
            try server.reload(mode: .open, phoneCertPath: phoneCertPath)
            bonjour.stop()
            bonjour.publish(port: server.port)
        } catch {
            statusLine = "Pairing restart failed: \(error.localizedDescription)"
        }
    }

    // A phone enrolled its certificate: lock down and close the pairing UI.
    private func lockAfterEnrollment() {
        relockIfEnrolled()
        qrWindow?.close()
    }

    private func relockIfEnrolled() {
        guard PhoneCertStore.loadTrustRoot(at: phoneCertPath) != nil else { return }
        enrollment?.setOpen(false)
        guard server.mode != .locked else { return }
        do {
            try server.reload(mode: .locked, phoneCertPath: phoneCertPath)
            bonjour.stop()
            bonjour.publish(port: server.port)
            statusLine = "Listening on port \(server.port)"
        } catch {
            // Keep the (still-running) open listener rather than going dark.
            statusLine = "Lock restart failed: \(error.localizedDescription)"
        }
    }

    private func qrContent(info: PairingInfo) -> AnyView {
        let payload = Pairing.qrPayload(info: info, port: server.port)
        let image = QRRenderer.image(from: payload, size: 300)
        return AnyView(
            VStack(spacing: 12) {
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
            .padding(24))
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
