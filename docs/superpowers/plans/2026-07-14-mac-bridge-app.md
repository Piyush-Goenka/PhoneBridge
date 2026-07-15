# Mac Bridge App Implementation Plan (Plan 1 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Swift menu bar app that receives notification JSON over authenticated HTTPS on the LAN, shows native macOS banners, and displays a pairing QR code. End-to-end testable without an Android phone via a fake-phone script.

**Architecture:** SPM package with a `PhoneBridgeCore` library (all logic, fully testable) and a thin `PhoneBridge` executable (SwiftUI MenuBarExtra). SwiftNIO + NIOSSL serve HTTPS; `NetService` advertises `_phonenotif._tcp` on Bonjour; `UNUserNotificationCenter` posts banners. Pairing material (self-signed cert, bearer token) is generated on first run via `/usr/bin/openssl` into Application Support.

**Tech Stack:** Swift 6.2 toolchain in Swift 5 language mode, SwiftNIO 2.65+, NIOSSL 2.27+, SwiftUI MenuBarExtra, UserNotifications, CoreImage (QR), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-14-android-mac-notification-bridge-design.md`

## Global Constraints

- Never use an em dash in any file, code comment, or document. Use a comma, colon, or parentheses.
- Never run `git commit` or `git push` without asking Piyush and receiving explicit permission at that moment. Commit steps below are phrased as "ask, then commit". If permission is not granted, skip the commit and continue.
- No global or system-wide package installs of any kind. Everything is project-local (SPM dependencies) or already on the machine.
- Default server port: 52735. If taken, bind an ephemeral port; Bonjour and the QR carry the actual port.
- Wire contract lives in `protocol.md` at repo root. If code and `protocol.md` disagree, fix the code.
- All work happens under `/Users/piyushgoenka/Desktop/New-Plans/Phone-Notification`.
- macOS attribution limitation is accepted: banners are attributed to PhoneBridge, with the Android app name as subtitle.

---

### Task 1: Repo scaffold, protocol.md, buildable SPM package

**Files:**
- Create: `.gitignore`
- Create: `protocol.md`
- Create: `mac/Package.swift`
- Create: `mac/Sources/PhoneBridgeCore/Placeholder.swift` (deleted in Task 2)
- Create: `mac/Sources/PhoneBridge/main.swift` (replaced in Task 6)
- Create: `mac/Tests/PhoneBridgeCoreTests/SmokeTests.swift` (replaced in Task 2)

**Interfaces:**
- Produces: an SPM package where `swift build` and `swift test` succeed, with NIO/NIOSSL resolved. Later tasks add files to `PhoneBridgeCore` without touching `Package.swift`.

- [ ] **Step 1: Initialize git repo**

```bash
cd /Users/piyushgoenka/Desktop/New-Plans/Phone-Notification
git init -b main
```

(`git init` is allowed; commits require permission.)

- [ ] **Step 2: Write .gitignore**

```gitignore
.DS_Store
.build/
build/
*.xcodeproj
.gradle/
android/local.properties
android/app/build/
android/build/
```

- [ ] **Step 3: Write protocol.md**

````markdown
# PhoneBridge wire protocol, v1

Source of truth for the Android to Mac contract. Both apps implement this file.

## Discovery

The Mac advertises Bonjour service type `_phonenotif._tcp.` (default port 52735,
but the advertised and QR port is authoritative). The phone resolves on demand,
caches host and port, and re-resolves once on connection failure.

## Security

- TLS with a self-signed certificate. The phone verifies nothing about the chain
  or hostname; it checks exactly one thing: SHA-256 of the leaf certificate DER
  equals the pinned fingerprint from the QR code.
- Every request carries `Authorization: Bearer <token>`. Missing or wrong token
  gets `401 {"error":"unauthorized"}`.

## Pairing QR payload (JSON, rendered as QR on the Mac)

```json
{"v":1,"host":"Piyushs-MacBook.local","port":52735,"token":"<base64url>","fp":"<64 hex chars, sha256 of cert DER>"}
```

## Endpoints (all POST, JSON bodies, JSON responses)

### POST /notify

```json
{
  "v": 1,
  "key": "0|com.whatsapp|1234|null|10123",
  "pkg": "com.whatsapp",
  "appName": "WhatsApp",
  "title": "Alice",
  "text": "see you at 6",
  "postedAt": 1768406400000,
  "iconHash": "sha256:ab12cd..."
}
```

Response `200 {"needIcon":true}` if `iconHash` is non-empty and unknown to the
Mac, else `200 {"needIcon":false}`. `iconHash` may be `""` (no icon available),
which never triggers `needIcon`.

### POST /icon

```json
{"iconHash": "sha256:ab12cd...", "png": "<base64 PNG bytes>"}
```

Response `200 {}`.

### POST /dismiss

```json
{"key": "0|com.whatsapp|1234|null|10123"}
```

Response `200 {}`. `key` matches a previous notify `key`; the Mac removes that
delivered notification. Unknown keys still return 200.

## Errors

- 401 bad/missing token, 400 malformed JSON, 404 unknown path.
- The phone treats any failure as drop-and-forget (best effort, no queue).
````

- [ ] **Step 4: Write mac/Package.swift**

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PhoneBridge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        .target(
            name: "PhoneBridgeCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]),
        .executableTarget(
            name: "PhoneBridge",
            dependencies: ["PhoneBridgeCore"]),
        .testTarget(
            name: "PhoneBridgeCoreTests",
            dependencies: ["PhoneBridgeCore"]),
    ]
)
```

- [ ] **Step 5: Write placeholder sources so the package builds**

`mac/Sources/PhoneBridgeCore/Placeholder.swift`:

```swift
public enum PhoneBridgeCore {
    public static let version = 1
}
```

`mac/Sources/PhoneBridge/main.swift`:

```swift
import PhoneBridgeCore

print("PhoneBridge core v\(PhoneBridgeCore.version)")
```

`mac/Tests/PhoneBridgeCoreTests/SmokeTests.swift`:

```swift
import XCTest
@testable import PhoneBridgeCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(PhoneBridgeCore.version, 1)
    }
}
```

- [ ] **Step 6: Build and test**

Run: `cd mac && swift build && swift test`
Expected: dependencies resolve (network fetch on first run), `Build complete!`, `Test Suite 'All tests' passed`.

- [ ] **Step 7: Ask Piyush for permission to commit; if granted:**

```bash
git add .gitignore protocol.md mac/
git commit -m "scaffold: SPM package, protocol v1"
```

---

### Task 2: Pairing (cert generation, token, fingerprint, QR payload)

**Files:**
- Create: `mac/Sources/PhoneBridgeCore/Pairing.swift`
- Delete: `mac/Sources/PhoneBridgeCore/Placeholder.swift`
- Test: `mac/Tests/PhoneBridgeCoreTests/PairingTests.swift` (replaces `SmokeTests.swift`, delete that file)

**Interfaces:**
- Produces:
  - `struct PairingInfo { let certPath: URL; let keyPath: URL; let fingerprint: String; let token: String }`
  - `enum Pairing { static func ensure(directory: URL) throws -> PairingInfo; static func qrPayload(info: PairingInfo, port: Int) -> String }`
  - Fingerprint is 64 lowercase hex chars, SHA-256 of the certificate DER. Token is 43-char base64url. Both stable across calls (generated once, then reloaded).

- [ ] **Step 1: Write the failing tests**

`mac/Tests/PhoneBridgeCoreTests/PairingTests.swift`:

```swift
import XCTest
@testable import PhoneBridgeCore

final class PairingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pairing-tests-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testGeneratesCertKeyAndToken() throws {
        let info = try Pairing.ensure(directory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.certPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.keyPath.path))
        XCTAssertFalse(info.token.isEmpty)
    }

    func testFingerprintIs64LowercaseHex() throws {
        let info = try Pairing.ensure(directory: dir)
        XCTAssertEqual(info.fingerprint.count, 64)
        XCTAssertTrue(info.fingerprint.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testStableAcrossCalls() throws {
        let first = try Pairing.ensure(directory: dir)
        let second = try Pairing.ensure(directory: dir)
        XCTAssertEqual(first.token, second.token)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    func testKeyAndTokenFilesArePrivate() throws {
        let info = try Pairing.ensure(directory: dir)
        for url in [info.keyPath, dir.appendingPathComponent("token")] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
        }
    }

    func testQRPayloadIsValidJSON() throws {
        let info = try Pairing.ensure(directory: dir)
        let payload = Pairing.qrPayload(info: info, port: 52735)
        let obj = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["v"] as? Int, 1)
        XCTAssertEqual(obj?["port"] as? Int, 52735)
        XCTAssertEqual(obj?["token"] as? String, info.token)
        XCTAssertEqual(obj?["fp"] as? String, info.fingerprint)
        XCTAssertFalse((obj?["host"] as? String ?? "").isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac && swift test`
Expected: FAIL, `cannot find 'Pairing' in scope`.

- [ ] **Step 3: Implement Pairing.swift, delete placeholder files**

Delete `mac/Sources/PhoneBridgeCore/Placeholder.swift` and `mac/Tests/PhoneBridgeCoreTests/SmokeTests.swift`.

`mac/Sources/PhoneBridgeCore/Pairing.swift`:

```swift
import Foundation
import CryptoKit
import Security

public struct PairingInfo {
    public let certPath: URL
    public let keyPath: URL
    public let fingerprint: String
    public let token: String
}

public enum PairingError: Error {
    case opensslFailed(Int32)
    case badPEM
}

public enum Pairing {
    public static func ensure(directory: URL) throws -> PairingInfo {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let certPath = directory.appendingPathComponent("cert.pem")
        let keyPath = directory.appendingPathComponent("key.pem")
        let tokenPath = directory.appendingPathComponent("token")

        if !fm.fileExists(atPath: certPath.path) || !fm.fileExists(atPath: keyPath.path) {
            try generateCert(certPath: certPath, keyPath: keyPath)
        }

        let token: String
        if let existing = try? String(contentsOf: tokenPath, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            token = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            token = randomToken()
            try token.write(to: tokenPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath.path)
        }

        return PairingInfo(
            certPath: certPath,
            keyPath: keyPath,
            fingerprint: try fingerprint(ofCertAt: certPath),
            token: token)
    }

    public static func qrPayload(info: PairingInfo, port: Int) -> String {
        let dict: [String: Any] = [
            "v": 1,
            "host": ProcessInfo.processInfo.hostName,
            "port": port,
            "token": info.token,
            "fp": info.fingerprint,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    static func generateCert(certPath: URL, keyPath: URL) throws {
        let host = ProcessInfo.processInfo.hostName
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyPath.path, "-out", certPath.path,
            "-days", "3650",
            "-subj", "/CN=PhoneBridge",
            "-addext", "subjectAltName=DNS:\(host),DNS:localhost,IP:127.0.0.1",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PairingError.opensslFailed(process.terminationStatus)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyPath.path)
    }

    static func fingerprint(ofCertAt url: URL) throws -> String {
        let pem = try String(contentsOf: url, encoding: .utf8)
        let base64 = pem
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let der = Data(base64Encoded: base64) else { throw PairingError.badPEM }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mac && swift test`
Expected: PASS, 5 tests. If `testKeyAndTokenFilesArePrivate` fails on key perms, check the LibreSSL invocation succeeded (`-addext` requires LibreSSL 3.1+; this machine has 3.3.6).

- [ ] **Step 5: Ask Piyush for permission to commit; if granted:**

```bash
git add mac/
git commit -m "feat(mac): pairing material generation and QR payload"
```

---

### Task 3: IconStore and RequestHandler (routing, auth, JSON)

**Files:**
- Create: `mac/Sources/PhoneBridgeCore/IconStore.swift`
- Create: `mac/Sources/PhoneBridgeCore/RequestHandler.swift`
- Test: `mac/Tests/PhoneBridgeCoreTests/RequestHandlerTests.swift`
- Test: `mac/Tests/PhoneBridgeCoreTests/IconStoreTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks (pure logic).
- Produces:
  - `struct NotifyPayload: Codable, Equatable { v: Int; key, pkg, appName, title, text: String; postedAt: Int64; iconHash: String }`
  - `struct HandlerResult: Equatable { let status: Int; let body: String }`
  - `protocol NotificationSink { func show(_ payload: NotifyPayload, iconPath: URL?); func dismiss(key: String) }`
  - `protocol IconStoring { func has(_ hash: String) -> Bool; func save(_ hash: String, png: Data) throws; func path(_ hash: String) -> URL? }`
  - `final class DiskIconStore: IconStoring { init(directory: URL) throws }`
  - `final class RequestHandler { init(token: String, icons: IconStoring, sink: NotificationSink); func handle(path: String, authorization: String?, body: Data) -> HandlerResult }`

- [ ] **Step 1: Write the failing tests**

`mac/Tests/PhoneBridgeCoreTests/RequestHandlerTests.swift`:

```swift
import XCTest
@testable import PhoneBridgeCore

final class MockIconStore: IconStoring {
    var stored: [String: Data] = [:]
    func has(_ hash: String) -> Bool { stored[hash] != nil }
    func save(_ hash: String, png: Data) throws { stored[hash] = png }
    func path(_ hash: String) -> URL? {
        stored[hash] != nil ? URL(fileURLWithPath: "/mock/\(hash)") : nil
    }
}

final class MockSink: NotificationSink {
    var shown: [NotifyPayload] = []
    var dismissed: [String] = []
    func show(_ payload: NotifyPayload, iconPath: URL?) { shown.append(payload) }
    func dismiss(key: String) { dismissed.append(key) }
}

final class RequestHandlerTests: XCTestCase {
    private var icons: MockIconStore!
    private var sink: MockSink!
    private var handler: RequestHandler!

    private let validNotify = """
        {"v":1,"key":"k1","pkg":"com.whatsapp","appName":"WhatsApp",\
        "title":"Alice","text":"hi","postedAt":1768406400000,"iconHash":"sha256:aa"}
        """

    override func setUp() {
        icons = MockIconStore()
        sink = MockSink()
        handler = RequestHandler(token: "secret", icons: icons, sink: sink)
    }

    private func post(_ path: String, auth: String?, body: String) -> HandlerResult {
        handler.handle(path: path, authorization: auth, body: Data(body.utf8))
    }

    func testMissingTokenIs401() {
        let r = post("/notify", auth: nil, body: validNotify)
        XCTAssertEqual(r.status, 401)
        XCTAssertTrue(sink.shown.isEmpty)
    }

    func testWrongTokenIs401() {
        let r = post("/notify", auth: "Bearer wrong", body: validNotify)
        XCTAssertEqual(r.status, 401)
        XCTAssertTrue(sink.shown.isEmpty)
    }

    func testValidNotifyShowsNotification() {
        let r = post("/notify", auth: "Bearer secret", body: validNotify)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(sink.shown.first?.title, "Alice")
        XCTAssertEqual(sink.shown.first?.appName, "WhatsApp")
    }

    func testUnknownIconHashRequestsIcon() {
        let r = post("/notify", auth: "Bearer secret", body: validNotify)
        XCTAssertEqual(r.body, #"{"needIcon":true}"#)
    }

    func testKnownIconHashDoesNotRequestIcon() throws {
        try icons.save("sha256:aa", png: Data([1]))
        let r = post("/notify", auth: "Bearer secret", body: validNotify)
        XCTAssertEqual(r.body, #"{"needIcon":false}"#)
    }

    func testEmptyIconHashNeverRequestsIcon() {
        let body = validNotify.replacingOccurrences(of: "sha256:aa", with: "")
        let r = post("/notify", auth: "Bearer secret", body: body)
        XCTAssertEqual(r.body, #"{"needIcon":false}"#)
    }

    func testMalformedJSONIs400() {
        let r = post("/notify", auth: "Bearer secret", body: "{nope")
        XCTAssertEqual(r.status, 400)
    }

    func testIconUploadStoresPNG() {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let r = post("/icon", auth: "Bearer secret",
                     body: #"{"iconHash":"sha256:bb","png":"\#(png)"}"#)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(icons.has("sha256:bb"))
    }

    func testDismissForwardsKey() {
        let r = post("/dismiss", auth: "Bearer secret", body: #"{"key":"k1"}"#)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(sink.dismissed, ["k1"])
    }

    func testUnknownPathIs404() {
        let r = post("/whatever", auth: "Bearer secret", body: "{}")
        XCTAssertEqual(r.status, 404)
    }
}
```

`mac/Tests/PhoneBridgeCoreTests/IconStoreTests.swift`:

```swift
import XCTest
@testable import PhoneBridgeCore

final class IconStoreTests: XCTestCase {
    func testSaveHasPathRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("icons-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try DiskIconStore(directory: dir)

        XCTAssertFalse(store.has("sha256:aa"))
        XCTAssertNil(store.path("sha256:aa"))

        try store.save("sha256:aa", png: Data([1, 2, 3]))
        XCTAssertTrue(store.has("sha256:aa"))
        let path = try XCTUnwrap(store.path("sha256:aa"))
        XCTAssertEqual(try Data(contentsOf: path), Data([1, 2, 3]))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac && swift test`
Expected: FAIL, `cannot find type 'IconStoring' in scope` and similar.

- [ ] **Step 3: Implement IconStore.swift**

```swift
import Foundation

public protocol IconStoring {
    func has(_ hash: String) -> Bool
    func save(_ hash: String, png: Data) throws
    func path(_ hash: String) -> URL?
}

public final class DiskIconStore: IconStoring {
    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(_ hash: String) -> URL {
        let safe = hash.replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe + ".png")
    }

    public func has(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(hash).path)
    }

    public func save(_ hash: String, png: Data) throws {
        try png.write(to: fileURL(hash))
    }

    public func path(_ hash: String) -> URL? {
        has(hash) ? fileURL(hash) : nil
    }
}
```

- [ ] **Step 4: Implement RequestHandler.swift**

```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd mac && swift test`
Expected: PASS, all tests (Pairing 5, RequestHandler 11, IconStore 1).

- [ ] **Step 6: Ask Piyush for permission to commit; if granted:**

```bash
git add mac/
git commit -m "feat(mac): request routing, auth, icon store"
```

---

### Task 4: Notifier (UNUserNotificationCenter sink) and GatedSink

**Files:**
- Create: `mac/Sources/PhoneBridgeCore/Notifier.swift`
- Create: `mac/Sources/PhoneBridgeCore/GatedSink.swift`
- Test: `mac/Tests/PhoneBridgeCoreTests/GatedSinkTests.swift`

**Interfaces:**
- Consumes: `NotifyPayload`, `NotificationSink` from Task 3.
- Produces:
  - `final class Notifier: NSObject, NotificationSink, UNUserNotificationCenterDelegate { func activate() }`. Every UserNotifications call is guarded by `Bundle.main.bundleIdentifier != nil` so `swift test` and `swift run` (unbundled) never crash; unbundled mode prints to stdout instead.
  - `final class GatedSink: NotificationSink { var enabled: Bool; init(wrapping: NotificationSink) }`, drops `show` when disabled, always forwards `dismiss`.

- [ ] **Step 1: Write the failing test**

`mac/Tests/PhoneBridgeCoreTests/GatedSinkTests.swift`:

```swift
import XCTest
@testable import PhoneBridgeCore

final class GatedSinkTests: XCTestCase {
    private let payload = NotifyPayload(
        v: 1, key: "k", pkg: "p", appName: "A",
        title: "t", text: "x", postedAt: 0, iconHash: "")

    func testForwardsWhenEnabled() {
        let inner = MockSink()
        let gated = GatedSink(wrapping: inner)
        gated.show(payload, iconPath: nil)
        XCTAssertEqual(inner.shown.count, 1)
    }

    func testDropsShowWhenDisabled() {
        let inner = MockSink()
        let gated = GatedSink(wrapping: inner)
        gated.enabled = false
        gated.show(payload, iconPath: nil)
        XCTAssertTrue(inner.shown.isEmpty)
    }

    func testAlwaysForwardsDismiss() {
        let inner = MockSink()
        let gated = GatedSink(wrapping: inner)
        gated.enabled = false
        gated.dismiss(key: "k")
        XCTAssertEqual(inner.dismissed, ["k"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac && swift test`
Expected: FAIL, `cannot find 'GatedSink' in scope`.

- [ ] **Step 3: Implement GatedSink.swift**

```swift
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
```

- [ ] **Step 4: Implement Notifier.swift**

```swift
import Foundation
import UserNotifications

public final class Notifier: NSObject, NotificationSink, UNUserNotificationCenterDelegate {
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    public override init() {
        super.init()
    }

    public func activate() {
        guard isBundled else {
            print("[dev] running unbundled, notifications print to stdout")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func show(_ payload: NotifyPayload, iconPath: URL?) {
        guard isBundled else {
            print("[dev] notify \(payload.appName): \(payload.title): \(payload.text)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = payload.title.isEmpty ? payload.appName : payload.title
        content.subtitle = payload.title.isEmpty ? "" : payload.appName
        content.body = payload.text
        content.sound = .default

        if let iconPath {
            // UNNotificationAttachment takes ownership of the file and moves it,
            // so attach a throwaway copy, never the cached original.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".png")
            if (try? FileManager.default.copyItem(at: iconPath, to: tmp)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "icon", url: tmp) {
                content.attachments = [attachment]
            }
        }

        let request = UNNotificationRequest(
            identifier: payload.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    public func dismiss(key: String) {
        guard isBundled else {
            print("[dev] dismiss \(key)")
            return
        }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [key])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd mac && swift test`
Expected: PASS, all tests.

- [ ] **Step 6: Ask Piyush for permission to commit; if granted:**

```bash
git add mac/
git commit -m "feat(mac): notification sink with mirroring gate"
```

---

### Task 5: BridgeServer (NIO + TLS) and Bonjour advertisement

**Files:**
- Create: `mac/Sources/PhoneBridgeCore/BridgeServer.swift`
- Create: `mac/Sources/PhoneBridgeCore/BonjourAdvertiser.swift`
- Test: `mac/Tests/PhoneBridgeCoreTests/ServerIntegrationTests.swift`

**Interfaces:**
- Consumes: `RequestHandler` (Task 3), `PairingInfo` cert/key paths (Task 2).
- Produces:
  - `final class BridgeServer { init(); private(set) var port: Int; func start(certPath: URL, keyPath: URL, handler: RequestHandler, preferredPort: Int = 52735) throws; func stop() }`. Binds preferredPort, falls back to an ephemeral port if taken; `port` reports the actual bound port. Passing `preferredPort: 0` binds ephemeral directly (used by tests).
  - `final class BonjourAdvertiser: NSObject { func publish(port: Int); func stop() }` advertising `_phonenotif._tcp.`.

- [ ] **Step 1: Write the failing integration test**

`mac/Tests/PhoneBridgeCoreTests/ServerIntegrationTests.swift`:

```swift
import XCTest
@testable import PhoneBridgeCore

final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class ServerIntegrationTests: XCTestCase {
    private var dir: URL!
    private var server: BridgeServer!
    private var sink: MockSink!
    private var session: URLSession!
    private var token: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-tests-" + UUID().uuidString)
        let info = try Pairing.ensure(directory: dir)
        token = info.token
        sink = MockSink()
        let handler = RequestHandler(
            token: info.token,
            icons: try DiskIconStore(directory: dir.appendingPathComponent("icons")),
            sink: sink)
        server = BridgeServer()
        try server.start(
            certPath: info.certPath, keyPath: info.keyPath,
            handler: handler, preferredPort: 0)
        session = URLSession(
            configuration: .ephemeral, delegate: TrustAllDelegate(), delegateQueue: nil)
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func post(_ path: String, auth: String?, body: String) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "https://localhost:\(server.port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        return ((response as! HTTPURLResponse).statusCode,
                String(data: data, encoding: .utf8) ?? "")
    }

    func testNotifyOverTLSRoundTrip() async throws {
        let body = """
            {"v":1,"key":"k1","pkg":"com.x","appName":"X","title":"Hello",\
            "text":"world","postedAt":0,"iconHash":""}
            """
        let (status, response) = try await post("/notify", auth: "Bearer \(token!)", body: body)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(response, #"{"needIcon":false}"#)
        XCTAssertEqual(sink.shown.first?.title, "Hello")
    }

    func testRejectsMissingToken() async throws {
        let (status, _) = try await post("/notify", auth: nil, body: "{}")
        XCTAssertEqual(status, 401)
    }

    func testBindsEphemeralPort() {
        XCTAssertGreaterThan(server.port, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac && swift test`
Expected: FAIL, `cannot find 'BridgeServer' in scope`.

- [ ] **Step 3: Implement BridgeServer.swift**

```swift
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

public final class BridgeServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    public private(set) var port: Int = 0

    public init() {}

    public func start(
        certPath: URL, keyPath: URL,
        handler: RequestHandler, preferredPort: Int = 52735
    ) throws {
        let certs = try NIOSSLCertificate.fromPEMFile(certPath.path)
            .map { NIOSSLCertificateSource.certificate($0) }
        let key = try NIOSSLPrivateKey(file: keyPath.path, format: .pem)
        let tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs, privateKey: .privateKey(key))
        let sslContext = try NIOSSLContext(configuration: tls)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline
                    .addHandler(NIOSSLServerHandler(context: sslContext))
                    .flatMap { channel.pipeline.configureHTTPServerPipeline() }
                    .flatMap { channel.pipeline.addHandler(HTTPHandler(handler: handler)) }
            }

        do {
            channel = try bootstrap.bind(host: "0.0.0.0", port: preferredPort).wait()
        } catch {
            channel = try bootstrap.bind(host: "0.0.0.0", port: 0).wait()
        }
        port = channel?.localAddress?.port ?? 0
    }

    public func stop() {
        try? channel?.close().wait()
        channel = nil
    }
}

final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let handler: RequestHandler
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(handler: RequestHandler) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let requestHead):
            head = requestHead
            body.clear()
        case .body(var chunk):
            body.writeBuffer(&chunk)
        case .end:
            guard let head else { return }
            let auth = head.headers.first(name: "Authorization")
            let result = handler.handle(
                path: head.uri,
                authorization: auth,
                body: Data(body.readableBytesView))

            var responseHead = HTTPResponseHead(
                version: head.version,
                status: HTTPResponseStatus(statusCode: result.status))
            let responseBody = context.channel.allocator.buffer(string: result.body)
            responseHead.headers.add(name: "Content-Type", value: "application/json")
            responseHead.headers.add(
                name: "Content-Length", value: String(responseBody.readableBytes))

            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(responseBody))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            self.head = nil
        }
    }
}
```

- [ ] **Step 4: Implement BonjourAdvertiser.swift**

```swift
import Foundation

public final class BonjourAdvertiser: NSObject {
    private var service: NetService?

    public func publish(port: Int) {
        let service = NetService(
            domain: "", type: "_phonenotif._tcp.",
            name: "PhoneBridge", port: Int32(port))
        service.publish()
        self.service = service
    }

    public func stop() {
        service?.stop()
        service = nil
    }
}
```

(`NetService` is deprecated; the warning is accepted per the spec.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd mac && swift test`
Expected: PASS, all tests including the three server integration tests.

- [ ] **Step 6: Ask Piyush for permission to commit; if granted:**

```bash
git add mac/
git commit -m "feat(mac): HTTPS server over NIO with Bonjour advertisement"
```

---

### Task 6: Menu bar app, QR window, app bundle, fake-phone script, smoke test

**Files:**
- Create: `mac/Sources/PhoneBridge/PhoneBridgeApp.swift` (replaces `main.swift`, delete that file)
- Create: `mac/Sources/PhoneBridge/AppState.swift`
- Create: `mac/Sources/PhoneBridge/QRRenderer.swift`
- Create: `mac/scripts/make-app.sh`
- Create: `mac/scripts/fake-phone.sh`

**Interfaces:**
- Consumes: everything from Tasks 2 to 5.
- Produces: `mac/build/PhoneBridge.app` (assembled by `make-app.sh`), and `fake-phone.sh` which exercises `/notify`, `/icon`, `/dismiss` against the running app using the real cert and token from `~/Library/Application Support/PhoneBridge/`.

- [ ] **Step 1: Delete main.swift, write PhoneBridgeApp.swift**

```swift
import SwiftUI
import ServiceManagement

@main
struct PhoneBridgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra("PhoneBridge", systemImage:
                        state.mirroring ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3.slash") {
            Text(state.statusLine)
            Divider()
            Toggle("Mirroring", isOn: $state.mirroring)
            Button("Show pairing QR") { state.showQRWindow() }
            Button(state.startsAtLogin ? "Disable start at login" : "Start at login") {
                state.toggleLoginItem()
            }
            Divider()
            Button("Quit PhoneBridge") { NSApplication.shared.terminate(nil) }
        }
    }
}
```

- [ ] **Step 2: Write AppState.swift**

```swift
import AppKit
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

    private let notifier = Notifier()
    private let gate: GatedSink
    private let server = BridgeServer()
    private let bonjour = BonjourAdvertiser()
    private var pairing: PairingInfo?
    private var qrWindow: NSWindow?

    init() {
        gate = GatedSink(wrapping: notifier)
        do {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PhoneBridge")
            let info = try Pairing.ensure(directory: dir)
            pairing = info
            let icons = try DiskIconStore(directory: dir.appendingPathComponent("icons"))
            let handler = RequestHandler(token: info.token, icons: icons, sink: gate)
            try server.start(certPath: info.certPath, keyPath: info.keyPath, handler: handler)
            bonjour.publish(port: server.port)
            notifier.activate()
            statusLine = "Listening on port \(server.port)"
        } catch {
            statusLine = "Failed to start: \(error.localizedDescription)"
        }
    }

    func showQRWindow() {
        guard let pairing else { return }
        let payload = Pairing.qrPayload(info: pairing, port: server.port)
        let image = QRRenderer.image(from: payload, size: 300)

        let content = VStack(spacing: 12) {
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
        .padding(24)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Pair your phone"
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        qrWindow = window
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
```

- [ ] **Step 3: Write QRRenderer.swift**

```swift
import AppKit
import CoreImage.CIFilterBuiltins

enum QRRenderer {
    static func image(from string: String, size: CGFloat) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return NSImage(size: .zero) }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
```

- [ ] **Step 4: Build to verify it compiles**

Run: `cd mac && swift build`
Expected: `Build complete!` (a deprecation warning for NetService is expected and accepted).

- [ ] **Step 5: Write make-app.sh**

`mac/scripts/make-app.sh`:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/PhoneBridge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/PhoneBridge "$APP/Contents/MacOS/PhoneBridge"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PhoneBridge</string>
    <key>CFBundleIdentifier</key><string>com.piyush.phonebridge</string>
    <key>CFBundleName</key><string>PhoneBridge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>PhoneBridge receives notifications from your Android phone over the local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_phonenotif._tcp</string></array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
```

Run: `chmod +x mac/scripts/make-app.sh`

- [ ] **Step 6: Write fake-phone.sh**

`mac/scripts/fake-phone.sh`:

```bash
#!/bin/bash
# Exercises a running PhoneBridge app: notify, icon upload, second notify, dismiss.
# Usage: fake-phone.sh [port]
set -euo pipefail

DIR="$HOME/Library/Application Support/PhoneBridge"
TOKEN=$(cat "$DIR/token")
PORT="${1:-52735}"
BASE="https://localhost:$PORT"
CURL=(curl -sS --cacert "$DIR/cert.pem"
      -H "Authorization: Bearer $TOKEN"
      -H "Content-Type: application/json")

KEY="fake|$$|$(date +%s)"

echo "== notify (no icon yet) =="
"${CURL[@]}" -d "{\"v\":1,\"key\":\"$KEY\",\"pkg\":\"com.fake\",\"appName\":\"FakePhone\",\
\"title\":\"Test notification\",\"text\":\"Hello from fake-phone.sh\",\
\"postedAt\":$(date +%s)000,\"iconHash\":\"sha256:fakeicon\"}" "$BASE/notify"
echo

echo "== icon upload =="
# 1x1 red PNG.
PNG="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
"${CURL[@]}" -d "{\"iconHash\":\"sha256:fakeicon\",\"png\":\"$PNG\"}" "$BASE/icon"
echo

echo "== notify again (icon now cached, expect needIcon false) =="
"${CURL[@]}" -d "{\"v\":1,\"key\":\"$KEY-2\",\"pkg\":\"com.fake\",\"appName\":\"FakePhone\",\
\"title\":\"With icon\",\"text\":\"This one has a thumbnail\",\
\"postedAt\":$(date +%s)000,\"iconHash\":\"sha256:fakeicon\"}" "$BASE/notify"
echo

echo "== dismiss the second one in 3 seconds =="
sleep 3
"${CURL[@]}" -d "{\"key\":\"$KEY-2\"}" "$BASE/dismiss"
echo
echo "Done. First banner should remain, second should be gone."
```

Run: `chmod +x mac/scripts/fake-phone.sh`

- [ ] **Step 7: Build the bundle and smoke test manually**

Run:

```bash
cd mac && ./scripts/make-app.sh && open build/PhoneBridge.app
```

Expected, in order (this step needs Piyush at the machine):
1. macOS asks to allow notifications from PhoneBridge: click Allow.
2. macOS may ask about local network access: click Allow.
3. A phone icon appears in the menu bar; its menu says "Listening on port 52735".
4. "Show pairing QR" opens a window with a QR code.
5. Run `./scripts/fake-phone.sh` in a terminal: two responses print (`{"needIcon":true}`, then `{}` and `{"needIcon":false}`), two banners appear, the second one disappears from Notification Center about 3 seconds later.
6. Toggle Mirroring off, run fake-phone again: HTTP 200s but no banners. Toggle back on.
7. `dns-sd -B _phonenotif._tcp` in a terminal lists `PhoneBridge`. Ctrl-C to stop.

If step 5 shows no banner despite 200 responses: check System Settings, Notifications, PhoneBridge, and set style to Banners or Alerts.

- [ ] **Step 8: Ask Piyush for permission to commit; if granted:**

```bash
git add mac/
git commit -m "feat(mac): menu bar app, QR pairing window, app bundle, fake-phone script"
```

---

## Plan 1 done criteria

- `cd mac && swift test` passes everything.
- `make-app.sh` produces a signed `PhoneBridge.app` that shows a menu bar icon, a QR window, and native banners driven by `fake-phone.sh`, including icon thumbnail and dismiss behaviour.
- `dns-sd -B _phonenotif._tcp` sees the advertisement.
