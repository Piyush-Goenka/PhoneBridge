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

// Rolling log of mirrored notifications, newest first. It is stored on disk
// only when the caller supplies an available at-rest encryption key.
public final class NotificationHistory {
    private let fileURL: URL
    private let cap: Int
    private let cipher: HistoryCipher
    private let persistenceEnabled: Bool
    private let lock = NSLock()
    private var stored: [HistoryEntry]

    public var onChange: (([HistoryEntry]) -> Void)?

    // Retention is deliberately short: only the most recent notifications are
    // worth keeping, and a smaller on-disk footprint means less to protect.
    public init(
        fileURL: URL, cap: Int = 20,
        cipher: HistoryCipher = PlaintextHistoryCipher(),
        persistenceEnabled: Bool = true
    ) {
        self.fileURL = fileURL
        self.cap = cap
        self.cipher = cipher
        self.persistenceEnabled = persistenceEnabled
        stored = []
        if persistenceEnabled, let data = try? Data(contentsOf: fileURL) {
            if let plaintext = try? cipher.open(data),
               let entries = try? JSONDecoder().decode([HistoryEntry].self, from: plaintext) {
                stored = Array(entries.prefix(cap))
            } else {
                // Unreadable with the current key: at best stale, at worst a
                // plaintext leftover from an older build. Remove it rather
                // than leaving it on disk.
                try? FileManager.default.removeItem(at: fileURL)
            }
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

    // Caller-name correction for a call already recorded: rewrite the newest
    // matching entry in place (same id, same position) instead of appending
    // a duplicate. Falls back to a fresh record when nothing matches.
    public func updateCall(key: String, caller: String) {
        rewriteCall(key: key) { old in
            HistoryEntry(
                id: old.id, key: old.key, appName: old.appName, title: caller,
                text: old.text, iconHash: old.iconHash, receivedAt: old.receivedAt,
                kind: old.kind)
        } ifMissing: {
            self.recordCall(key: key, caller: caller)
        }
    }

    // A call answered from the Mac reads better in history as "Answered call"
    // than as a bare incoming call.
    public func markCallAnswered(key: String) {
        rewriteCall(key: key) { old in
            HistoryEntry(
                id: old.id, key: old.key, appName: old.appName, title: old.title,
                text: "Answered call", iconHash: old.iconHash,
                receivedAt: old.receivedAt, kind: old.kind)
        } ifMissing: {}
    }

    private func rewriteCall(
        key: String,
        _ transform: (HistoryEntry) -> HistoryEntry,
        ifMissing: () -> Void
    ) {
        lock.lock()
        guard let index = stored.firstIndex(where: { $0.key == key && $0.isCall }) else {
            lock.unlock()
            ifMissing()
            return
        }
        stored[index] = transform(stored[index])
        let snapshot = stored
        lock.unlock()
        save(snapshot)
        onChange?(snapshot)
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
        guard persistenceEnabled else { return }
        guard let plaintext = try? JSONEncoder().encode(entries),
              let data = try? cipher.seal(plaintext) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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

    public func updateCall(key: String, caller: String) {
        history.updateCall(key: key, caller: caller)
        inner.updateCall(key: key, caller: caller)
    }

    public func setCallState(key: String, state: CallState) {
        if state == .active { history.markCallAnswered(key: key) }
        inner.setCallState(key: key, state: state)
    }

    public func endCall(key: String) {
        inner.endCall(key: key)
    }
}
