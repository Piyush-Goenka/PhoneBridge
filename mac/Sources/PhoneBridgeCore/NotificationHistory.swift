import Foundation

public struct HistoryEntry: Codable, Equatable, Identifiable {
    public let id: UUID
    public let key: String
    public let appName: String
    public let title: String
    public let text: String
    public let iconHash: String
    public let receivedAt: Double

    public init(
        id: UUID = UUID(), key: String, appName: String, title: String,
        text: String, iconHash: String, receivedAt: Double
    ) {
        self.id = id
        self.key = key
        self.appName = appName
        self.title = title
        self.text = text
        self.iconHash = iconHash
        self.receivedAt = receivedAt
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
        let entry = HistoryEntry(
            key: payload.key,
            appName: payload.appName,
            title: payload.title,
            text: payload.text,
            iconHash: payload.iconHash,
            receivedAt: Date().timeIntervalSince1970)
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
