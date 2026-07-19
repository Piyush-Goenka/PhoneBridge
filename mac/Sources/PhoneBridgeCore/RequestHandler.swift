import Foundation

public struct NotifyPayload: Codable, Equatable {
    public let v: Int
    public let key: String
    public let pkg: String
    public let appName: String
    public let title: String
    public let text: String
    public let postedAt: Int64
    public let iconHash: String
}

public struct IconPayload: Codable {
    public let iconHash: String
    public let png: String
}

public struct DismissPayload: Codable {
    public let key: String
}

public struct CallPayload: Codable {
    public let v: Int
    public let key: String
    public let caller: String
    public let postedAt: Int64
    // true marks a caller-name refresh for an already-shown call; absent
    // (old phones) means a new call.
    public let update: Bool?
    // "active" (answered from the Mac) or "silenced"; absent means neither.
    public let state: String?
}

// How the phone reports a call has changed while its card is up.
public enum CallState: String {
    case active
    case silenced
}

public struct CallWaitPayload: Codable {
    public let key: String
}

public struct HandlerResult: Equatable {
    public let status: Int
    public let body: String
    public init(status: Int, body: String) {
        self.status = status
        self.body = body
    }
}

public protocol NotificationSink {
    func show(_ payload: NotifyPayload, iconPath: URL?)
    func dismiss(key: String)
}

public protocol CallSink {
    func showCall(key: String, caller: String)
    func updateCall(key: String, caller: String)
    func setCallState(key: String, state: CallState)
    func endCall(key: String)
}

public final class RequestHandler {
    private let token: String
    private let icons: IconStoring
    private let sink: NotificationSink
    private let calls: CallActionRegistry
    private let callSink: CallSink

    public init(
        token: String, icons: IconStoring, sink: NotificationSink,
        calls: CallActionRegistry, callSink: CallSink
    ) {
        self.token = token
        self.icons = icons
        self.sink = sink
        self.calls = calls
        self.callSink = callSink
    }

    public func handle(path: String, authorization: String?, body: Data) -> HandlerResult {
        guard authorization == "Bearer \(token)" else {
            return HandlerResult(status: 401, body: #"{"error":"unauthorized"}"#)
        }
        switch path {
        case "/notify":
            guard let payload = try? JSONDecoder().decode(NotifyPayload.self, from: body) else {
                return HandlerResult(status: 400, body: #"{"error":"bad json"}"#)
            }
            let needIcon = !payload.iconHash.isEmpty && !icons.has(payload.iconHash)
            sink.show(payload, iconPath: icons.path(payload.iconHash))
            return HandlerResult(
                status: 200,
                body: needIcon ? #"{"needIcon":true}"# : #"{"needIcon":false}"#)
        case "/icon":
            guard let payload = try? JSONDecoder().decode(IconPayload.self, from: body),
                  let png = Data(base64Encoded: payload.png) else {
                return HandlerResult(status: 400, body: #"{"error":"bad json"}"#)
            }
            do {
                try icons.save(payload.iconHash, png: png)
            } catch {
                return HandlerResult(status: 500, body: #"{"error":"store failed"}"#)
            }
            return HandlerResult(status: 200, body: "{}")
        case "/dismiss":
            guard let payload = try? JSONDecoder().decode(DismissPayload.self, from: body) else {
                return HandlerResult(status: 400, body: #"{"error":"bad json"}"#)
            }
            sink.dismiss(key: payload.key)
            calls.cancel(key: payload.key)
            callSink.endCall(key: payload.key)
            return HandlerResult(status: 200, body: "{}")
        case "/call":
            guard let payload = try? JSONDecoder().decode(CallPayload.self, from: body) else {
                return HandlerResult(status: 400, body: #"{"error":"bad json"}"#)
            }
            if let raw = payload.state, let state = CallState(rawValue: raw) {
                callSink.setCallState(key: payload.key, state: state)
            } else if payload.update == true {
                callSink.updateCall(key: payload.key, caller: payload.caller)
            } else {
                callSink.showCall(key: payload.key, caller: payload.caller)
            }
            return HandlerResult(status: 200, body: "{}")
        default:
            return HandlerResult(status: 404, body: #"{"error":"not found"}"#)
        }
    }

    public func handleAsync(
        path: String, authorization: String?, body: Data,
        completion: @escaping (HandlerResult) -> Void
    ) {
        guard path == "/call/wait" else {
            completion(handle(path: path, authorization: authorization, body: body))
            return
        }
        guard authorization == "Bearer \(token)" else {
            completion(HandlerResult(status: 401, body: #"{"error":"unauthorized"}"#))
            return
        }
        guard let payload = try? JSONDecoder().decode(CallWaitPayload.self, from: body) else {
            completion(HandlerResult(status: 400, body: #"{"error":"bad json"}"#))
            return
        }
        calls.register(key: payload.key) { action in
            completion(HandlerResult(status: 200, body: #"{"action":"\#(action.rawValue)"}"#))
        }
    }
}
