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

public final class RequestHandler {
    private let token: String
    private let icons: IconStoring
    private let sink: NotificationSink

    public init(token: String, icons: IconStoring, sink: NotificationSink) {
        self.token = token
        self.icons = icons
        self.sink = sink
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
            return HandlerResult(status: 200, body: "{}")
        default:
            return HandlerResult(status: 404, body: #"{"error":"not found"}"#)
        }
    }
}
