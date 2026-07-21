import Foundation
import CryptoKit

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

public struct EnrollPayload: Codable {
    public let v: Int
    public let cert: String
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
    private let enroller: PhoneEnroller?
    // Injectable clock so timestamp-freshness tests are deterministic.
    private let now: () -> Date

    // Freshness bounds for postedAt (#13): a generous 24 h past window
    // (re-posted ongoing notifications keep older timestamps) and 1 h of
    // future clock skew. Both phones and Macs are NTP-synced in practice.
    private static let maxPastSkew: TimeInterval = 24 * 3600
    private static let maxFutureSkew: TimeInterval = 3600

    // Field bounds (#15): generous for real content, tight enough that a
    // stolen token cannot stuff megabytes into history or the UI.
    private static let maxKey = 256
    private static let maxPkg = 256
    private static let maxAppName = 128
    private static let maxTitle = 512
    private static let maxText = 4096
    private static let maxCaller = 256
    private static let maxIconBytes = 512 * 1024

    private static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    public init(
        token: String, icons: IconStoring, sink: NotificationSink,
        calls: CallActionRegistry, callSink: CallSink,
        enroller: PhoneEnroller? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.token = token
        self.icons = icons
        self.sink = sink
        self.calls = calls
        self.callSink = callSink
        self.enroller = enroller
        self.now = now
    }

    // Constant-time bearer check (#12): compare SHA-256 digests with a full
    // XOR fold, so neither content nor length differences short-circuit.
    private func authorized(_ authorization: String?) -> Bool {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return false }
        let provided = Data(SHA256.hash(data: Data(authorization.dropFirst("Bearer ".count).utf8)))
        let expected = Data(SHA256.hash(data: Data(token.utf8)))
        var diff: UInt8 = 0
        for (a, b) in zip(provided, expected) { diff |= a ^ b }
        return diff == 0
    }

    private func isFresh(_ postedAtMillis: Int64) -> Bool {
        let posted = Double(postedAtMillis) / 1000
        let current = now().timeIntervalSince1970
        return posted >= current - Self.maxPastSkew && posted <= current + Self.maxFutureSkew
    }

    // Either empty (no icon) or exactly "sha256:" + 64 lowercase hex, which
    // also guarantees the IconStore filename is safe.
    static func isValidIconHash(_ hash: String) -> Bool {
        if hash.isEmpty { return true }
        guard hash.hasPrefix("sha256:"), hash.count == 71 else { return false }
        return hash.dropFirst(7).allSatisfy { "0123456789abcdef".contains($0) }
    }

    private func reject(_ status: Int, _ error: String) -> HandlerResult {
        HandlerResult(status: status, body: #"{"error":"\#(error)"}"#)
    }

    public func handle(
        path: String, authorization: String?, body: Data, method: String = "POST"
    ) -> HandlerResult {
        // Every endpoint is a POST (#17); reject other verbs before any work.
        guard method == "POST" else {
            return reject(405, "method not allowed")
        }
        guard authorized(authorization) else {
            return reject(401, "unauthorized")
        }
        switch path {
        case "/notify":
            guard let payload = try? JSONDecoder().decode(NotifyPayload.self, from: body) else {
                return reject(400, "bad json")
            }
            guard payload.v == 1 else { return reject(400, "bad version") }
            guard !payload.key.isEmpty, payload.key.count <= Self.maxKey,
                  payload.pkg.count <= Self.maxPkg,
                  payload.appName.count <= Self.maxAppName,
                  payload.title.count <= Self.maxTitle,
                  payload.text.count <= Self.maxText,
                  Self.isValidIconHash(payload.iconHash) else {
                return reject(400, "bad field")
            }
            guard isFresh(payload.postedAt) else { return reject(400, "stale timestamp") }
            let needIcon = !payload.iconHash.isEmpty && !icons.has(payload.iconHash)
            sink.show(payload, iconPath: icons.path(payload.iconHash))
            return HandlerResult(
                status: 200,
                body: needIcon ? #"{"needIcon":true}"# : #"{"needIcon":false}"#)
        case "/icon":
            guard let payload = try? JSONDecoder().decode(IconPayload.self, from: body),
                  let png = Data(base64Encoded: payload.png) else {
                return reject(400, "bad json")
            }
            // The bytes must be a PNG whose SHA-256 matches the claimed hash
            // (#16), so a compromised phone cannot park arbitrary content
            // under a hash another notification will reference.
            guard Self.isValidIconHash(payload.iconHash), !payload.iconHash.isEmpty,
                  png.count <= Self.maxIconBytes,
                  png.starts(with: Self.pngMagic) else {
                return reject(400, "bad icon")
            }
            let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            guard payload.iconHash == "sha256:\(digest)" else {
                return reject(400, "hash mismatch")
            }
            do {
                try icons.save(payload.iconHash, png: png)
            } catch {
                return reject(500, "store failed")
            }
            return HandlerResult(status: 200, body: "{}")
        case "/dismiss":
            guard let payload = try? JSONDecoder().decode(DismissPayload.self, from: body) else {
                return reject(400, "bad json")
            }
            guard !payload.key.isEmpty, payload.key.count <= Self.maxKey else {
                return reject(400, "bad field")
            }
            sink.dismiss(key: payload.key)
            calls.cancel(key: payload.key)
            callSink.endCall(key: payload.key)
            return HandlerResult(status: 200, body: "{}")
        case "/call":
            guard let payload = try? JSONDecoder().decode(CallPayload.self, from: body) else {
                return reject(400, "bad json")
            }
            guard payload.v == 1 else { return reject(400, "bad version") }
            guard !payload.key.isEmpty, payload.key.count <= Self.maxKey,
                  payload.caller.count <= Self.maxCaller else {
                return reject(400, "bad field")
            }
            guard isFresh(payload.postedAt) else { return reject(400, "stale timestamp") }
            if let raw = payload.state, let state = CallState(rawValue: raw) {
                callSink.setCallState(key: payload.key, state: state)
            } else if payload.update == true {
                callSink.updateCall(key: payload.key, caller: payload.caller)
            } else {
                callSink.showCall(key: payload.key, caller: payload.caller)
            }
            return HandlerResult(status: 200, body: "{}")
        case "/enroll":
            guard let enroller else {
                return HandlerResult(status: 404, body: #"{"error":"not found"}"#)
            }
            guard let payload = try? JSONDecoder().decode(EnrollPayload.self, from: body),
                  payload.v == 1,
                  let der = Data(base64Encoded: payload.cert) else {
                return HandlerResult(status: 400, body: #"{"error":"bad json"}"#)
            }
            switch enroller.enroll(certDer: der) {
            case .accepted:
                return HandlerResult(status: 200, body: "{}")
            case .locked:
                return HandlerResult(status: 403, body: #"{"error":"locked"}"#)
            case .invalid:
                return HandlerResult(status: 400, body: #"{"error":"bad cert"}"#)
            case .failed:
                return HandlerResult(status: 500, body: #"{"error":"store failed"}"#)
            }
        default:
            return HandlerResult(status: 404, body: #"{"error":"not found"}"#)
        }
    }

    public func handleAsync(
        path: String, authorization: String?, body: Data, method: String = "POST",
        completion: @escaping (HandlerResult) -> Void
    ) {
        guard path == "/call/wait" else {
            completion(handle(path: path, authorization: authorization, body: body, method: method))
            return
        }
        guard method == "POST" else {
            completion(reject(405, "method not allowed"))
            return
        }
        guard authorized(authorization) else {
            completion(reject(401, "unauthorized"))
            return
        }
        guard let payload = try? JSONDecoder().decode(CallWaitPayload.self, from: body) else {
            completion(reject(400, "bad json"))
            return
        }
        guard !payload.key.isEmpty, payload.key.count <= Self.maxKey else {
            completion(reject(400, "bad field"))
            return
        }
        calls.register(key: payload.key) { action in
            completion(HandlerResult(status: 200, body: #"{"action":"\#(action.rawValue)"}"#))
        }
    }
}
