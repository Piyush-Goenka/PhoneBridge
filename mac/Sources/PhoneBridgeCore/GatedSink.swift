import Foundation

public final class GatedSink: NotificationSink, CallSink {
    // Flipped from the UI thread, read on the server's event loop for every
    // incoming notification: guarded so a toggle is always seen promptly and
    // the cross-thread access is well-defined.
    private let lock = NSLock()
    private var _enabled = true
    public var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }
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

    public func updateCall(key: String, caller: String) {
        guard enabled, let callInner else { return }
        callInner.updateCall(key: key, caller: caller)
    }

    public func setCallState(key: String, state: CallState) {
        guard enabled, let callInner else { return }
        callInner.setCallState(key: key, state: state)
    }

    public func endCall(key: String) {
        // Like dismiss, cleanup always flows through even when mirroring is off,
        // so a panel shown before the toggle flipped cannot get stuck.
        callInner?.endCall(key: key)
    }
}
