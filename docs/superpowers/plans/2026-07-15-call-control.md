# Call Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the phone rings, the Mac banner offers Reject and Silence buttons whose clicks act on the phone within the ring window.

**Architecture:** The phone detects the dialer's CATEGORY_CALL notification, POSTs `/call`, then long-polls `/call/wait` (held up to 45 s by a new Mac-side `CallActionRegistry`). Mac banners for calls use a `CALL` notification category with action buttons; clicks fulfill the pending wait. Phone executes reject (TelecomManager.endCall) or silence (ringer mode flip with restore), both guarded by a live is-ringing check.

**Tech Stack:** Existing codebases: Swift/SwiftNIO/UserNotifications on Mac; Kotlin/OkHttp/NotificationListenerService on Android. New Android APIs: TelecomManager, TelephonyManager, AudioManager, NotificationManager DND policy.

**Spec:** `docs/superpowers/specs/2026-07-15-call-control-design.md`

## Global Constraints

- Never use an em dash in any file, code comment, or document.
- Never run `git commit` or `git push` without asking Piyush and receiving explicit permission at that moment.
- Wire additions: `POST /call` `{"v":1,"key","caller","postedAt"}` returns `200 {}`; `POST /call/wait` `{"key"}` held at most 45 s returns `200 {"action":"reject"|"silence"|"none"}`. Both bearer-token gated like all endpoints.
- Battery principle: the wait request exists only during a ring; nothing persists after.
- Both actions execute on the phone only while the call state is RINGING.
- All existing tests must keep passing (Mac 23, Android 24) plus the new ones.

---

### Task 1: Mac core: CallActionRegistry, CallSink, /call and /call/wait routing (TDD)

**Files:**
- Create: `mac/Sources/PhoneBridgeCore/CallActionRegistry.swift`
- Modify: `mac/Sources/PhoneBridgeCore/RequestHandler.swift` (new payloads, CallSink protocol, new init params, `/call` case, `handleAsync`, `/dismiss` fulfills)
- Modify: `mac/Sources/PhoneBridgeCore/GatedSink.swift` (CallSink conformance)
- Test: `mac/Tests/PhoneBridgeCoreTests/CallActionRegistryTests.swift`
- Test: `mac/Tests/PhoneBridgeCoreTests/RequestHandlerTests.swift` (MockCallSink + new cases + updated constructor)
- Test: `mac/Tests/PhoneBridgeCoreTests/ServerIntegrationTests.swift` (updated constructor only)
- Test: `mac/Tests/PhoneBridgeCoreTests/GatedSinkTests.swift` (call gating test)
- Modify: `protocol.md` (two new endpoint sections)

**Interfaces:**
- Consumes: existing `RequestHandler`, `HandlerResult`, `NotificationSink`, `GatedSink`.
- Produces:
  - `enum CallAction: String { case reject, silence, none }`
  - `final class CallActionRegistry { init(timeout: TimeInterval = 45); func register(key: String, completion: @escaping (CallAction) -> Void); func fulfill(key: String, action: CallAction) }` (fulfill is idempotent, register schedules a timeout fulfill of .none, re-register fulfills the previous completion with .none)
  - `protocol CallSink { func showCall(key: String, caller: String) }`
  - `struct CallPayload: Codable { v: Int; key, caller: String; postedAt: Int64 }`, `struct CallWaitPayload: Codable { key: String }`
  - `RequestHandler.init(token:icons:sink:calls:callSink:)` and `func handleAsync(path: String, authorization: String?, body: Data, completion: @escaping (HandlerResult) -> Void)` (all paths except `/call/wait` complete synchronously via the existing `handle`)
  - `GatedSink.init(wrapping: NotificationSink, calls: CallSink? = nil)` conforming to `CallSink`, dropping `showCall` when disabled.

- [ ] **Step 1: Write the failing tests**

`mac/Tests/PhoneBridgeCoreTests/CallActionRegistryTests.swift`:

```swift
import XCTest
@testable import PhoneBridgeCore

final class CallActionRegistryTests: XCTestCase {
    func testFulfillDeliversActionOnce() {
        let registry = CallActionRegistry(timeout: 10)
        var received: [CallAction] = []
        registry.register(key: "k") { received.append($0) }
        registry.fulfill(key: "k", action: .reject)
        registry.fulfill(key: "k", action: .silence)
        XCTAssertEqual(received, [.reject])
    }

    func testTimeoutDeliversNone() {
        let registry = CallActionRegistry(timeout: 0.1)
        let expectation = expectation(description: "timeout")
        registry.register(key: "k") { action in
            XCTAssertEqual(action, .none)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testReRegisterFulfillsPreviousWithNone() {
        let registry = CallActionRegistry(timeout: 10)
        var first: CallAction?
        registry.register(key: "k") { first = $0 }
        registry.register(key: "k") { _ in }
        XCTAssertEqual(first, CallAction.none)
    }

    func testFulfillUnknownKeyIsHarmless() {
        let registry = CallActionRegistry(timeout: 10)
        registry.fulfill(key: "missing", action: .reject)
    }
}
```

Additions to `RequestHandlerTests.swift`. Add the mock next to MockSink:

```swift
final class MockCallSink: CallSink {
    var calls: [(key: String, caller: String)] = []
    func showCall(key: String, caller: String) { calls.append((key, caller)) }
}
```

Update `setUp` to the new constructor (this fixes the compile break for every existing test):

```swift
    private var callSink: MockCallSink!
    private var registry: CallActionRegistry!

    override func setUp() {
        icons = MockIconStore()
        sink = MockSink()
        callSink = MockCallSink()
        registry = CallActionRegistry(timeout: 10)
        handler = RequestHandler(
            token: "secret", icons: icons, sink: sink,
            calls: registry, callSink: callSink)
    }
```

New test methods:

```swift
    func testCallShowsActionableBanner() {
        let body = #"{"v":1,"key":"c1","caller":"Palak","postedAt":0}"#
        let r = post("/call", auth: "Bearer secret", body: body)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(callSink.calls.first?.key, "c1")
        XCTAssertEqual(callSink.calls.first?.caller, "Palak")
    }

    func testCallMalformedIs400() {
        XCTAssertEqual(post("/call", auth: "Bearer secret", body: "{nope").status, 400)
    }

    func testCallWaitCompletesWhenFulfilled() {
        let expectation = expectation(description: "wait")
        handler.handleAsync(
            path: "/call/wait", authorization: "Bearer secret",
            body: Data(#"{"key":"c1"}"#.utf8)) { result in
            XCTAssertEqual(result.status, 200)
            XCTAssertEqual(result.body, #"{"action":"silence"}"#)
            expectation.fulfill()
        }
        registry.fulfill(key: "c1", action: .silence)
        wait(for: [expectation], timeout: 2)
    }

    func testCallWaitBadTokenIs401() {
        let expectation = expectation(description: "wait")
        handler.handleAsync(
            path: "/call/wait", authorization: "Bearer wrong",
            body: Data(#"{"key":"c1"}"#.utf8)) { result in
            XCTAssertEqual(result.status, 401)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testDismissFulfillsPendingWaitWithNone() {
        let expectation = expectation(description: "wait")
        handler.handleAsync(
            path: "/call/wait", authorization: "Bearer secret",
            body: Data(#"{"key":"c1"}"#.utf8)) { result in
            XCTAssertEqual(result.body, #"{"action":"none"}"#)
            expectation.fulfill()
        }
        _ = post("/dismiss", auth: "Bearer secret", body: #"{"key":"c1"}"#)
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(sink.dismissed, ["c1"])
    }

    func testHandleAsyncPassesThroughSyncPaths() {
        let expectation = expectation(description: "sync")
        handler.handleAsync(path: "/whatever", authorization: "Bearer secret", body: Data("{}".utf8)) { result in
            XCTAssertEqual(result.status, 404)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
```

Addition to `GatedSinkTests.swift`:

```swift
    func testDropsCallWhenDisabled() {
        let inner = MockSink()
        let callInner = MockCallSink()
        let gated = GatedSink(wrapping: inner, calls: callInner)
        gated.enabled = false
        gated.showCall(key: "k", caller: "X")
        XCTAssertTrue(callInner.calls.isEmpty)
        gated.enabled = true
        gated.showCall(key: "k", caller: "X")
        XCTAssertEqual(callInner.calls.count, 1)
    }
```

Update `ServerIntegrationTests.swift` setUp constructor call to:

```swift
        let handler = RequestHandler(
            token: info.token,
            icons: try DiskIconStore(directory: dir.appendingPathComponent("icons")),
            sink: sink,
            calls: CallActionRegistry(),
            callSink: MockCallSink())
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac && swift test`
Expected: FAIL to compile, `cannot find 'CallActionRegistry' in scope`.

- [ ] **Step 3: Implement CallActionRegistry.swift**

```swift
import Foundation

public enum CallAction: String {
    case reject
    case silence
    case none
}

public final class CallActionRegistry {
    private let lock = NSLock()
    private var pending: [String: (CallAction) -> Void] = [:]
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 45) {
        self.timeout = timeout
    }

    public func register(key: String, completion: @escaping (CallAction) -> Void) {
        lock.lock()
        let previous = pending[key]
        pending[key] = completion
        lock.unlock()
        previous?(.none)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.fulfill(key: key, action: .none)
        }
    }

    public func fulfill(key: String, action: CallAction) {
        lock.lock()
        let completion = pending.removeValue(forKey: key)
        lock.unlock()
        completion?(action)
    }
}
```

- [ ] **Step 4: Extend RequestHandler.swift**

Add after the existing payload structs:

```swift
public struct CallPayload: Codable {
    public let v: Int
    public let key: String
    public let caller: String
    public let postedAt: Int64
}

public struct CallWaitPayload: Codable {
    public let key: String
}

public protocol CallSink {
    func showCall(key: String, caller: String)
}
```

Change the class properties and init:

```swift
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
```

Add a `/call` case to the switch in `handle`, before `default`:

```swift
        case "/call":
            guard let payload = try? JSONDecoder().decode(CallPayload.self, from: body) else {
                return HandlerResult(status: 400, body: #"{"error":"bad json"}"#)
            }
            callSink.showCall(key: payload.key, caller: payload.caller)
            return HandlerResult(status: 200, body: "{}")
```

Extend the `/dismiss` case so a pending wait ends when the ring stops (add one line before the return):

```swift
        case "/dismiss":
            guard let payload = try? JSONDecoder().decode(DismissPayload.self, from: body) else {
                return HandlerResult(status: 400, body: #"{"error":"bad json"}"#)
            }
            sink.dismiss(key: payload.key)
            calls.fulfill(key: payload.key, action: .none)
            return HandlerResult(status: 200, body: "{}")
```

Add the async entry point after `handle`:

```swift
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
```

- [ ] **Step 5: Extend GatedSink.swift**

```swift
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
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd mac && swift test`
Expected: PASS, 23 prior (with updated constructors) + 4 registry + 6 handler + 1 gate = 34 tests.

- [ ] **Step 7: Update protocol.md**

Add before the Errors section:

```markdown
### POST /call

```json
{"v":1,"key":"0|com.google.android.dialer|1|null|10","caller":"Palak","postedAt":1768500000000}
```

Response `200 {}`. Shows an actionable Incoming Call banner (Reject, Silence) on the Mac.

### POST /call/wait

```json
{"key":"0|com.google.android.dialer|1|null|10"}
```

Held open by the Mac for up to 45 seconds, then `200 {"action":"reject"|"silence"|"none"}`.
The action reflects the button clicked on the Mac banner; `none` means timeout or
banner dismissed. Clients must use a read timeout of at least 50 seconds for this
endpoint only. A phone-side `/dismiss` for the same key (ring ended) fulfills any
pending wait with `none`.
```

- [ ] **Step 8: Ask Piyush for permission to commit; if granted:**

```bash
git add mac/ protocol.md
git commit -m "feat(mac): call action registry and call endpoints"
```

---

### Task 2: Mac wiring: async HTTP, CALL notification category, AppState, fake-call script

**Files:**
- Modify: `mac/Sources/PhoneBridgeCore/BridgeServer.swift` (HTTPHandler .end goes through handleAsync)
- Modify: `mac/Sources/PhoneBridgeCore/Notifier.swift` (CALL category, showCall, didReceive delegate, onCallAction)
- Modify: `mac/Sources/PhoneBridge/AppState.swift` (registry wiring)
- Create: `mac/scripts/fake-call.sh`

**Interfaces:**
- Consumes: `CallActionRegistry`, `CallSink`, `RequestHandler.handleAsync` (Task 1).
- Produces: `Notifier: CallSink` with `var onCallAction: ((String, CallAction) -> Void)?`; a running app where a `/call` POST shows a banner with working Reject and Silence buttons that answer `/call/wait`.

- [ ] **Step 1: Rework HTTPHandler's .end case in BridgeServer.swift**

Replace the `.end` case body with (keep the existing `tooLarge` handling in `.body` untouched; if `tooLarge` was set, the response has already been written, so just clear state and return):

```swift
        case .end:
            guard let head else { return }
            self.head = nil
            if tooLarge { return }
            let auth = head.headers.first(name: "Authorization")
            let requestBody = Data(body.readableBytesView)
            let version = head.version
            let loop = context.eventLoop
            let ctx = context
            handler.handleAsync(path: head.uri, authorization: auth, body: requestBody) { result in
                loop.execute {
                    var responseHead = HTTPResponseHead(
                        version: version,
                        status: HTTPResponseStatus(statusCode: result.status))
                    let responseBody = ctx.channel.allocator.buffer(string: result.body)
                    responseHead.headers.add(name: "Content-Type", value: "application/json")
                    responseHead.headers.add(
                        name: "Content-Length", value: String(responseBody.readableBytes))
                    ctx.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(responseBody))), promise: nil)
                    ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                }
            }
```

(The completion may fire up to 45 s later on a different thread; `loop.execute` hops back to this channel's event loop. If the client disconnected meanwhile, the writes on the closed channel are discarded, which is acceptable.)

- [ ] **Step 2: Extend Notifier.swift**

Add the callback property and CallSink conformance:

```swift
public final class Notifier: NSObject, NotificationSink, CallSink, UNUserNotificationCenterDelegate {

    public var onCallAction: ((String, CallAction) -> Void)?
```

In `activate(onDenied:)`, after `center.delegate = self`, register the category:

```swift
        let reject = UNNotificationAction(
            identifier: "REJECT", title: "Reject", options: [.destructive])
        let silence = UNNotificationAction(
            identifier: "SILENCE", title: "Silence", options: [])
        let callCategory = UNNotificationCategory(
            identifier: "CALL", actions: [reject, silence],
            intentIdentifiers: [], options: [.customDismissAction])
        center.setNotificationCategories([callCategory])
```

Add the call banner and the response delegate:

```swift
    public func showCall(key: String, caller: String) {
        guard isBundled else {
            print("[dev] incoming call from \(caller)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Incoming call"
        content.body = caller
        content.sound = .default
        content.categoryIdentifier = "CALL"
        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let request = response.notification.request
        guard request.content.categoryIdentifier == "CALL" else { return }
        let action: CallAction
        switch response.actionIdentifier {
        case "REJECT": action = .reject
        case "SILENCE": action = .silence
        default: action = .none
        }
        onCallAction?(request.identifier, action)
    }
```

- [ ] **Step 3: Wire AppState.swift**

Add a registry property and update init wiring:

```swift
    private let callRegistry = CallActionRegistry()
```

Change the gate construction and handler construction, and hook the callback (inside `init`, replacing the existing two lines):

```swift
        gate = GatedSink(wrapping: notifier, calls: notifier)
        ...
        let handler = RequestHandler(
            token: info.token, icons: icons, sink: gate,
            calls: callRegistry, callSink: gate)
        ...
        notifier.onCallAction = { [callRegistry] key, action in
            callRegistry.fulfill(key: key, action: action)
        }
```

- [ ] **Step 4: Write fake-call.sh**

`mac/scripts/fake-call.sh`:

```bash
#!/bin/bash
# Simulates a ringing phone: shows the actionable call banner, then waits
# for the button click and prints which action came back.
set -euo pipefail

DIR="$HOME/Library/Application Support/PhoneBridge"
TOKEN=$(cat "$DIR/token")
PORT="${1:-52735}"
BASE="https://localhost:$PORT"
CURL=(curl -sS --cacert "$DIR/cert.pem"
      -H "Authorization: Bearer $TOKEN"
      -H "Content-Type: application/json")

KEY="fakecall|$$"

echo "== call banner =="
"${CURL[@]}" -d "{\"v\":1,\"key\":\"$KEY\",\"caller\":\"Fake Caller\",\"postedAt\":$(date +%s)000}" "$BASE/call"
echo
echo "== waiting up to 45s: click Reject or Silence on the banner =="
"${CURL[@]}" --max-time 55 -d "{\"key\":\"$KEY\"}" "$BASE/call/wait"
echo
```

Run: `chmod +x mac/scripts/fake-call.sh`

- [ ] **Step 5: Build, test, rebuild bundle**

Run: `cd mac && swift build && swift test && ./scripts/make-app.sh`
Expected: Build complete, all 34 tests pass, `Built build/PhoneBridge.app`.

- [ ] **Step 6: Manual check (needs Piyush at the Mac)**

Relaunch the app (`osascript -e 'quit app "PhoneBridge"'; open mac/build/PhoneBridge.app`), run `mac/scripts/fake-call.sh`, hover the banner, click Silence. The script should print `{"action":"silence"}`. Run again and let it time out: after 45 s it prints `{"action":"none"}`.

- [ ] **Step 7: Ask Piyush for permission to commit; if granted:**

```bash
git add mac/
git commit -m "feat(mac): actionable call banners over async HTTP"
```

---

### Task 3: Android client: mirrorCalls flag and call endpoints (TDD)

**Files:**
- Modify: `android/app/src/main/java/com/piyush/phonebridge/pairing/PairingStore.kt`
- Modify: `android/app/src/main/java/com/piyush/phonebridge/net/MacClient.kt`
- Test: `android/app/src/test/java/com/piyush/phonebridge/net/MacClientTest.kt` (new cases)

**Interfaces:**
- Consumes: existing `MacClient` internals (`client`, `jsonType`, `post`).
- Produces:
  - `PairingStore.mirrorCallsEnabled: Boolean` (default false, key "mirrorCalls")
  - `MacClient.postCall(host, port, json): SendResult`
  - `MacClient.WaitResult` sealed interface: `data class Action(val action: String)`, `data class Failed(val reason: String)`
  - `MacClient.postCallWait(host, port, json): WaitResult` using a derived OkHttp client with a 55 s read timeout.

- [ ] **Step 1: Write the failing tests (add to MacClientTest.kt)**

```kotlin
    @Test
    fun callHitsCallPath() {
        server.enqueue(MockResponse().setBody("{}"))
        val client = MacClient("tok", fingerprint)
        client.postCall(server.hostName, server.port, """{"v":1}""")
        assertEquals("/call", server.takeRequest().path)
    }

    @Test
    fun callWaitParsesAction() {
        server.enqueue(MockResponse().setBody("""{"action":"reject"}"""))
        val client = MacClient("tok", fingerprint)
        val result = client.postCallWait(server.hostName, server.port, """{"key":"k"}""")
        assertEquals(MacClient.WaitResult.Action("reject"), result)
        assertEquals("/call/wait", server.takeRequest().path)
    }

    @Test
    fun callWaitDefaultsToNoneOnMissingField() {
        server.enqueue(MockResponse().setBody("{}"))
        val client = MacClient("tok", fingerprint)
        assertEquals(
            MacClient.WaitResult.Action("none"),
            client.postCallWait(server.hostName, server.port, """{"key":"k"}"""))
    }

    @Test
    fun callWaitConnectionFailureIsFailed() {
        val port = server.port
        server.shutdown()
        val client = MacClient("tok", fingerprint)
        assertTrue(
            client.postCallWait("localhost", port, """{"key":"k"}""")
                is MacClient.WaitResult.Failed)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd android && ./gradlew :app:testDebugUnitTest`
Expected: compilation FAILS, unresolved reference `postCall`.

- [ ] **Step 3: Add the flag to PairingStore.kt**

```kotlin
    var mirrorCallsEnabled: Boolean
        get() = prefs.getBoolean("mirrorCalls", false)
        set(value) = prefs.edit().putBoolean("mirrorCalls", value).apply()
```

- [ ] **Step 4: Extend MacClient.kt**

Add inside the class:

```kotlin
    sealed interface WaitResult {
        data class Action(val action: String) : WaitResult
        data class Failed(val reason: String) : WaitResult
    }

    private val waitClient: OkHttpClient by lazy {
        client.newBuilder().readTimeout(55, TimeUnit.SECONDS).build()
    }

    fun postCall(host: String, port: Int, json: String): SendResult =
        post(host, port, "/call", json)

    fun postCallWait(host: String, port: Int, json: String): WaitResult {
        val request = Request.Builder()
            .url("https://$host:$port/call/wait")
            .header("Authorization", "Bearer $token")
            .post(json.toRequestBody(jsonType))
            .build()
        return try {
            waitClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    WaitResult.Failed("HTTP ${response.code}")
                } else {
                    val body = response.body?.string() ?: ""
                    val action = try {
                        org.json.JSONObject(body).optString("action", "none")
                    } catch (e: org.json.JSONException) {
                        "none"
                    }
                    WaitResult.Action(action)
                }
            }
        } catch (e: Exception) {
            WaitResult.Failed(e.message ?: e.javaClass.simpleName)
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd android && ./gradlew :app:testDebugUnitTest`
Expected: `BUILD SUCCESSFUL`, 28 tests (24 prior + 4 new).

- [ ] **Step 6: Ask Piyush for permission to commit; if granted:**

```bash
git add android/
git commit -m "feat(android): call endpoints in MacClient, mirrorCalls flag"
```

---

### Task 4: Android: CallControl and the relay call path

**Files:**
- Create: `android/app/src/main/java/com/piyush/phonebridge/relay/CallControl.kt`
- Modify: `android/app/src/main/java/com/piyush/phonebridge/relay/NotificationRelayService.kt`
- Modify: `android/app/src/main/AndroidManifest.xml` (two permissions)

**Interfaces:**
- Consumes: `MacClient.postCall/postCallWait/WaitResult` (Task 3), `PairingStore.mirrorCallsEnabled` (Task 3), existing `deliveredKeys`, `clientFor`, `SendLog`.
- Produces: `object CallControl { fun isRinging(Context): Boolean; fun reject(Context): String; fun silence(Context): String; fun onRingEnded(Context) }` where the String returns are human-readable outcomes for the send log.

- [ ] **Step 1: Write CallControl.kt**

```kotlin
package com.piyush.phonebridge.relay

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.telecom.TelecomManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat

object CallControl {

    @Volatile
    private var savedRingerMode: Int? = null

    private fun granted(context: Context, permission: String) =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED

    fun isRinging(context: Context): Boolean {
        if (!granted(context, Manifest.permission.READ_PHONE_STATE)) return false
        val telephony =
            context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
        @Suppress("DEPRECATION")
        return telephony.callState == TelephonyManager.CALL_STATE_RINGING
    }

    fun reject(context: Context): String {
        if (!granted(context, Manifest.permission.ANSWER_PHONE_CALLS)) {
            return "reject failed: no permission"
        }
        if (!isRinging(context)) return "reject skipped: not ringing"
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        @Suppress("DEPRECATION")
        val ended = try {
            telecom.endCall()
        } catch (e: SecurityException) {
            false
        }
        return if (ended) "call rejected" else "reject failed"
    }

    fun silence(context: Context): String {
        val notifications =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!notifications.isNotificationPolicyAccessGranted) {
            return "silence failed: no DND access"
        }
        if (!isRinging(context)) return "silence skipped: not ringing"
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (savedRingerMode == null) savedRingerMode = audio.ringerMode
        audio.ringerMode = AudioManager.RINGER_MODE_SILENT
        return "ringer silenced"
    }

    fun onRingEnded(context: Context) {
        val saved = savedRingerMode ?: return
        savedRingerMode = null
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audio.ringerMode = saved
    }
}
```

- [ ] **Step 2: Add the call path to NotificationRelayService.kt**

Add a field next to `deliveredKeys`:

```kotlin
    private val activeCallKeys: MutableSet<String> =
        Collections.synchronizedSet(HashSet())
```

In `onNotificationPosted`'s coroutine, after `extract` and the `isPaired`/`mirroringEnabled` gate but BEFORE the `NotificationFilter.shouldForward` check, add:

```kotlin
            if (notification.category == "call" && store.mirrorCallsEnabled) {
                if (CallControl.isRinging(this@NotificationRelayService) &&
                    activeCallKeys.add(notification.key)
                ) {
                    handleCall(notification, store)
                }
                return@launch
            }
```

Add the session function:

```kotlin
    private suspend fun handleCall(n: RelayNotification, store: PairingStore) {
        val macClient = clientFor(store) ?: return
        val host = store.host ?: return
        val caller = n.title.ifBlank { n.text.ifBlank { "Unknown caller" } }

        val callBody = JSONObject()
            .put("v", 1)
            .put("key", n.key)
            .put("caller", caller)
            .put("postedAt", n.postedAt)
            .toString()
        val posted = macClient.postCall(host, store.port, callBody)
        if (posted !is MacClient.SendResult.Ok) {
            SendLog.add("Call", caller, "call dropped: Mac unreachable")
            activeCallKeys.remove(n.key)
            return
        }
        deliveredKeys.add(n.key)
        SendLog.add("Call", caller, "ringing on Mac")

        val waitBody = JSONObject().put("key", n.key).toString()
        when (val wait = macClient.postCallWait(host, store.port, waitBody)) {
            is MacClient.WaitResult.Action -> when (wait.action) {
                "reject" -> SendLog.add(
                    "Call", caller, CallControl.reject(this@NotificationRelayService))
                "silence" -> {
                    SendLog.add(
                        "Call", caller, CallControl.silence(this@NotificationRelayService))
                    scope.launch {
                        kotlinx.coroutines.delay(60_000)
                        CallControl.onRingEnded(this@NotificationRelayService)
                    }
                }
                else -> {}
            }
            is MacClient.WaitResult.Failed ->
                SendLog.add("Call", caller, "call wait failed: ${wait.reason}")
        }
    }
```

In `onNotificationRemoved`, add call cleanup as the FIRST lines of the method (before the `deliveredKeys` gate, since the call key is also in `deliveredKeys` and must continue into the existing `/dismiss` send):

```kotlin
        if (activeCallKeys.remove(sbn.key)) {
            CallControl.onRingEnded(this)
        }
```

- [ ] **Step 3: Add permissions to AndroidManifest.xml**

After the CAMERA permission line:

```xml
    <uses-permission android:name="android.permission.READ_PHONE_STATE" />
    <uses-permission android:name="android.permission.ANSWER_PHONE_CALLS" />
```

- [ ] **Step 4: Build and test**

Run: `cd android && ./gradlew :app:assembleDebug :app:testDebugUnitTest`
Expected: `BUILD SUCCESSFUL`, 28 tests passing.

- [ ] **Step 5: Ask Piyush for permission to commit; if granted:**

```bash
git add android/
git commit -m "feat(android): call session relay with reject and silence execution"
```

---

### Task 5: Android UI toggle, permission flow, install, acceptance

**Files:**
- Modify: `android/app/src/main/java/com/piyush/phonebridge/ui/MainActivity.kt`
- Modify: `android/app/src/main/java/com/piyush/phonebridge/ui/MainScreen.kt`

**Interfaces:**
- Consumes: `PairingStore.mirrorCallsEnabled` (Task 3).
- Produces: a "Mirror calls" switch in the status card that requests `ANSWER_PHONE_CALLS` + `READ_PHONE_STATE` on enable and deep-links to DND access if missing.

- [ ] **Step 1: Extend MainActivity.kt**

Add imports:

```kotlin
import android.Manifest
import android.app.NotificationManager
```

Add the launcher next to scanLauncher:

```kotlin
    private val callPermissionLauncher = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()
    ) { }
```

Add the toggle handler method:

```kotlin
    private fun onMirrorCallsChanged(enabled: Boolean) {
        store.mirrorCallsEnabled = enabled
        if (!enabled) return
        callPermissionLauncher.launch(
            arrayOf(
                Manifest.permission.ANSWER_PHONE_CALLS,
                Manifest.permission.READ_PHONE_STATE))
        val notifications = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (!notifications.isNotificationPolicyAccessGranted) {
            Toast.makeText(
                this,
                "Allow Do Not Disturb access so Silence can quiet the ringer",
                Toast.LENGTH_LONG).show()
            startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))
        }
    }
```

Pass it into MainScreen (add parameter to the call):

```kotlin
                MainScreen(
                    store = store,
                    paired = paired,
                    accessGranted = accessGranted,
                    onEnableAccess = { ... existing ... },
                    onScanQr = { ... existing ... },
                    onMirrorCalls = ::onMirrorCallsChanged,
                )
```

- [ ] **Step 2: Extend MainScreen.kt**

Add the parameter:

```kotlin
fun MainScreen(
    store: PairingStore,
    paired: MutableState<Boolean>,
    accessGranted: MutableState<Boolean>,
    onEnableAccess: () -> Unit,
    onScanQr: () -> Unit,
    onMirrorCalls: (Boolean) -> Unit,
) {
```

Add state next to `mirroring`:

```kotlin
    var mirrorCalls by remember { mutableStateOf(store.mirrorCallsEnabled) }
```

Add a row in the status card Column, after the Mirroring row:

```kotlin
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Mirror calls (Reject and Silence from Mac)",
                            modifier = Modifier.weight(1f))
                        Switch(checked = mirrorCalls, onCheckedChange = {
                            mirrorCalls = it
                            onMirrorCalls(it)
                        })
                    }
```

- [ ] **Step 3: Build, test, install**

Run:

```bash
cd android && ./gradlew :app:assembleDebug :app:testDebugUnitTest
~/Library/Android/sdk/platform-tools/adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Expected: BUILD SUCCESSFUL, 28 tests, `Success`. (If the wireless adb connection dropped, reconnect via `adb connect <phone-ip>:<port>` first.)

- [ ] **Step 4: Acceptance (needs Piyush, the phone, and a second phone to call from)**

| # | Action | Expected |
|---|---|---|
| 1 | Enable "Mirror calls", grant the permission dialog, enable DND access for PhoneBridge in the Settings screen that opens | Toggle stays on |
| 2 | Call the phone from another number | Mac banner "Incoming call: <name/number>" with Reject and Silence buttons within a second |
| 3 | Click Silence | Ringer goes quiet, call keeps ringing on screen; after it ends, ringer mode is restored |
| 4 | Call again, click Reject | Call ends (caller goes to voicemail/busy); banner leaves Notification Center when the ring stops |
| 5 | Call again, answer on the phone, then click Reject on the (stale) Mac banner | Nothing happens to the active call; phone log shows "reject skipped: not ringing" |
| 6 | Call again, ignore everything | Ring proceeds normally; banner disappears when ring ends; log shows no action |

- [ ] **Step 5: Ask Piyush for permission to commit; if granted:**

```bash
git add android/
git commit -m "feat(android): mirror-calls toggle with permission flow"
```

---

## Done criteria

- Mac: 34 tests pass; fake-call.sh round-trips a button click.
- Android: 28 tests pass; acceptance matrix passes on real hardware.
- Battery: no polling or persistent connections outside the ring window.
