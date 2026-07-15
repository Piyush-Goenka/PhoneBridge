import Foundation

public final class GatedSink: NotificationSink, CallSink {
    public var enabled = true
    private let inner: NotificationSink
    private let callInner: CallSink?

    public init(wrapping inner: NotificationSink, calls: CallSink? = nil) {
        self.inner = inner
        self.callInner = calls
    }

    public func show(_ payload: NotifyPayload, iconPath: URL?) {
        guard enabled else { return }
        inner.show(payload, iconPath: iconPath)
    }

    public func dismiss(key: String) {
        inner.dismiss(key: key)
    }

    public func showCall(key: String, caller: String) {
        guard enabled, let callInner else { return }
        callInner.showCall(key: key, caller: caller)
    }

    public func endCall(key: String) {
        // Like dismiss, cleanup always flows through even when mirroring is off,
        // so a panel shown before the toggle flipped cannot get stuck.
        callInner?.endCall(key: key)
    }
}
