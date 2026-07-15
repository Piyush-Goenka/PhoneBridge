import Foundation

public final class GatedSink: NotificationSink {
    public var enabled = true
    private let inner: NotificationSink

    public init(wrapping inner: NotificationSink) {
        self.inner = inner
    }

    public func show(_ payload: NotifyPayload, iconPath: URL?) {
        guard enabled else { return }
        inner.show(payload, iconPath: iconPath)
    }

    public func dismiss(key: String) {
        inner.dismiss(key: key)
    }
}
