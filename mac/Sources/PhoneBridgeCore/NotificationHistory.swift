import Foundation

public struct HistoryEntry: Codable, Equatable, Identifiable {
    public let id: UUID
    public let key: String
    public let appName: String
    public let title: String
    public let text: String
    public let iconHash: String
    public let receivedAt: Double
    // "call" marks a mirrored call; nil for a normal notification. Optional so
    // history written before this field decodes cleanly.
    public let kind: String?

    public var isCall: Bool { kind == "call" }

    public init(
        id: UUID = UUID(), key: String, appName: String, title: String,
        text: String, iconHash: String, receivedAt: Double, kind: String? = nil
    ) {
        self.id = id
        self.key = key
        self.appName = appName
        self.title = title
        self.text = text
        self.iconHash = iconHash
        self.receivedAt = receivedAt
        self.kind = kind
    }
}

// Rolling on-disk log of mirrored notifications, newest first. This is the
// Mac-side history now that cards replaced Notification Center.
public final class NotificationHistory {
    private let fileURL: URL
    private let cap: Int
    private let lock = NSLock()
    private var stored: [HistoryEntry]

    public var onChange: (([HistoryEntry]) -> Void)?

    public init(fileURL: URL, cap: Int = 200) {
        self.fileURL = fileURL
        self.cap = cap
        if let data = try? Data(contentsOf: fileURL),
           let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            stored = entries
        } else {
            stored = []
        }
    }

    public var entries: [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func record(_ payload: NotifyPayload) {
        append(HistoryEntry(
            key: payload.key,
            appName: payload.appName,
            title: payload.title,
            text: payload.text,
            iconHash: payload.iconHash,
            receivedAt: Date().timeIntervalSince1970))
    }

    public func recordCall(key: String, caller: String) {
        append(HistoryEntry(
            key: key,
            appName: "Phone",
            title: caller,
            text: "Incoming call",
            iconHash: "",
            receivedAt: Date().timeIntervalSince1970,
            kind: "call"))
    }

    private func append(_ entry: HistoryEntry) {
        lock.lock()
        stored = Array(([entry] + stored).prefix(cap))
        let snapshot = stored
        lock.unlock()
        save(snapshot)
        onChange?(snapshot)
    }

    public func clear() {
        lock.lock()
        stored = []
        lock.unlock()
        save([])
        onChange?([])
    }

    private func save(_ entries: [HistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

// Records every shown notification into history, then forwards to the
// display sink. Sits inside the mirroring gate, so a disabled toggle means
// no card and no history entry.
public final class HistorySink: NotificationSink {
    private let inner: NotificationSink
    private let history: NotificationHistory

    public init(wrapping inner: NotificationSink, history: NotificationHistory) {
        self.inner = inner
        self.history = history
    }

    public func show(_ payload: NotifyPayload, iconPath: URL?) {
        history.record(payload)
        inner.show(payload, iconPath: iconPath)
    }

    public func dismiss(key: String) {
        inner.dismiss(key: key)
    }
}

// Records every mirrored call into history, then forwards to the call panel.
// Sits inside the mirroring gate, mirroring HistorySink for notifications.
public final class CallHistorySink: CallSink {
    private let inner: CallSink
    private let history: NotificationHistory

    public init(wrapping inner: CallSink, history: NotificationHistory) {
        self.inner = inner
        self.history = history
    }

    public func showCall(key: String, caller: String) {
        history.recordCall(key: key, caller: caller)
        inner.showCall(key: key, caller: caller)
    }

    public func endCall(key: String) {
        inner.endCall(key: key)
    }
}
