# Android → Mac Notification Bridge, Design

Date: 2026-07-14
Status: Approved, ready for planning

## Goal

When a notification arrives on my Android phone, show it on my Mac, provided both are on the same local network. Read-only mirror: I see the notification, I don't act on it from the Mac.

## Principles

These drove every decision below, and any future change should be checked against them.

1. **Battery work is event-driven only.** The phone does work at exactly one moment: when Android hands it a notification. Nothing polls, nothing holds an open socket, nothing browses the network in the background, nothing wakes on a timer. If no notification arrives, the app costs nothing.
2. **Best-effort delivery, no state.** If the Mac isn't reachable, the notification is dropped. No queue, no database, no retry-on-reconnect, no TTL bookkeeping. A notification I couldn't deliver is not worth engineering around.
3. **The notification stream is sensitive.** It contains OTPs, 2FA codes, and message previews. It is encrypted on the wire and authenticated on both ends, even though it never leaves the LAN.
4. **Silence by default.** Android is noisy. Nothing is mirrored unless I explicitly opted the app in.

## Architecture

Two applications and one JSON contract.

```
Android phone                          Mac
─────────────                          ───
NotificationListenerService
  │ (Android wakes it on a notification)
  ▼
NotificationFilter  ── drop ──▶ (nothing happens)
  │ forward
  ▼
MacDiscovery (mDNS, on-demand)  ◀────  Bonjour: _phonenotif._tcp
  │ resolved host:port
  ▼
MacClient ── HTTPS POST /notify ─────▶ BridgeServer (NIO + TLS)
             (bearer token,                  │ token valid?
              pinned cert)                   ▼
                                        UNUserNotificationCenter
                                             │
                                             ▼
                                        native macOS banner
```

### Transport

The Mac runs a small HTTPS server and advertises it on the LAN via Bonjour as `_phonenotif._tcp`. The phone resolves that service on demand, when it has something to send, and issues a single POST. Fire-and-forget: on failure, drop and move on.

Discovery is on-demand, not continuous. The phone caches the last resolved host and port and tries it first; if that fails, it re-resolves via mDNS once, then gives up. This keeps discovery inside the notification event, honouring principle 1.

### Security: QR pairing, TLS, bearer token

On first launch, the Mac generates a self-signed TLS certificate and a random token. It renders `{host, port, token, certFingerprint}` into a QR code shown in the menu bar app. The phone scans it once.

Thereafter:
- Every request carries the token. The Mac 401s anything else, so a hostile device on the LAN cannot post fake notifications.
- The phone pins the certificate fingerprint from the QR and refuses any other certificate, so nothing on the LAN can read the notification stream or impersonate the Mac.

A fingerprint mismatch or a 401 fails loudly in the phone UI as "re-pair needed", rather than silently.

### Filtering

Three gates, all on the phone, all before anything touches the network:

1. **Structural.** Drop ongoing notifications, foreground-service notifications, group summaries, and the media/transport/progress categories. This is what removes Spotify's per-second re-posts and Google Maps navigation updates, which would otherwise dominate the stream.
2. **Allowlist.** Only apps I have explicitly enabled are forwarded. Empty by default.
3. **Dedup.** A hash of (package, title, text) against a short-lived in-memory cache, because Android re-posts identical notifications routinely.

### Icons

The POST carries only a hash of the app icon, never the image. If the Mac has not seen that hash before, it responds `{"needIcon": true}`, and the phone follows with a one-time `POST /icon` carrying the PNG. Each app's icon therefore crosses the network exactly once, ever, and is cached on disk by the Mac. It renders as the banner's thumbnail.

### Dismissal

`onNotificationRemoved` fires when I clear a notification on the phone. The phone sends `POST /dismiss` with the notification key, and the Mac calls `removeDeliveredNotifications` so the banner leaves Notification Center. I clear a message once, not twice.

This is best-effort like everything else: if the Mac is unreachable, the dismiss is dropped. There is one visible consequence, and it is accepted rather than solved: if the Mac received a notification and then went to sleep, dismissing it on the phone leaves that banner in the Mac's Notification Center until it is cleared there. Fixing this would require a queue, which principle 2 rules out.

### macOS presentation (amended 2026-07-15)

Originally the Mac showed native macOS notifications, which attribute every banner to the bridge app and cannot show the originating app's icon in the icon slot. This was replaced at Piyush's request: the Mac now renders mirrored notifications as custom floating cards (top-right corner, real app icon from the icon cache, app name, title, text). Cards auto-dismiss after about 6 seconds, close early when the notification is cleared on the phone, stack newest-on-top below any active call panel, and can be clicked away. Tradeoff accepted knowingly: no Notification Center history; a missed card is gone from the Mac (it remains on the phone). UNUserNotificationCenter is no longer used at all, so no notification permission is needed.

## Wire protocol

`POST /notify`
```json
{
  "v": 1,
  "key": "0|com.whatsapp|1234|null|10123",
  "pkg": "com.whatsapp",
  "appName": "WhatsApp",
  "title": "Alice",
  "text": "see you at 6",
  "postedAt": 1768406400000,
  "iconHash": "sha256:ab12…"
}
```
Response: `200 {"needIcon": false}` or `200 {"needIcon": true}`.

`POST /icon` → `{"iconHash": "sha256:ab12…", "png": "<base64>"}` → `200`.

`POST /dismiss` → `{"key": "0|com.whatsapp|1234|null|10123"}` → `200`.

All requests carry `Authorization: Bearer <token>`. Anything without it gets a 401.

`protocol.md` at the repo root is the source of truth for this contract. Neither codebase is.

## Components

### Android (`android/`, Kotlin)

- **`NotificationRelayService`**, the `NotificationListenerService` subclass. Deliberately thin: converts a `StatusBarNotification` into a plain data class and hands it off. Requires the "Notification access" permission, which cannot be requested with a normal dialog and must deep-link into Settings.
- **`NotificationFilter`**, a pure function over that data class returning forward-or-drop. No Android imports, so it is unit-testable on the JVM with no emulator. This is the piece most likely to need tuning, so it is the piece that must be trivial to test.
- **`MacDiscovery`**, wraps `NsdManager`. On-demand resolution with a cached host/port.
- **`MacClient`**, OkHttp with a `TrustManager` that accepts exactly the pinned fingerprint, plus the bearer token. Owns the try-once-then-drop policy and the icon follow-up.
- **UI**, one screen: pairing status, scan-QR, the app allowlist, and a log of recent send attempts with outcomes.

### Mac (`mac/`, Swift, menu bar)

- **`BridgeServer`**, SwiftNIO + NIOSSL serving `/notify`, `/icon`, `/dismiss`. 401s anything without a valid token.
- **`Pairing`**, generates the certificate and token on first run, stores them as 0600 files in Application Support, renders the QR with CoreImage. (Not Keychain: the app is ad-hoc signed and re-signed on every rebuild, which changes the code signature and breaks Keychain ACL matching, causing repeated permission failures. Filesystem permissions on a single-user machine are the right trade.)
- **`NotificationCardController`** (amended 2026-07-15), renders each mirrored notification as a floating card with the cached app icon; replaces the earlier `Notifier`/`UNUserNotificationCenter` approach.
- **`MenuBarApp`**, SwiftUI `MenuBarExtra`: status, mirroring on/off, the QR sheet, launch-at-login via `SMAppService`.

Bonjour advertisement runs alongside the NIO server via Foundation's `NetService`. It is deprecated but fully functional on macOS 15, and the alternative (`NWListener`) would couple advertisement to its own connection handling and force abandoning NIO's HTTP stack. Decision settled during planning: `NetService`, accepting the deprecation warning.

## Failure modes

| Situation | Behaviour |
|---|---|
| Mac asleep or off | POST fails, notification dropped, attempt logged in the phone's recent-sends list so it is debuggable rather than mysterious |
| Phone on cellular or another network | mDNS finds nothing, notification dropped silently |
| Certificate fingerprint mismatch | Phone refuses the connection and surfaces "re-pair needed". Fails loudly, since the alternative is a silent man-in-the-middle |
| Bad or missing token | Mac returns 401, phone surfaces "re-pair needed" |
| Notification access revoked by Android | App detects the service is unbound and prompts back into Settings |

## Testing

- **JVM unit tests on `NotificationFilter` and the dedup cache**, with fixtures for the real-world spam cases: a Spotify media notification, a Maps navigation update, a group summary, and the same WhatsApp message posted twice.
- **Swift unit tests on the request handler**: valid token accepted, missing token 401, wrong token 401, malformed JSON 400, unknown icon hash triggers `needIcon`.
- **A `fake-phone` test client** that POSTs a real payload to a running Mac app with the pinned certificate. This is the end-to-end check that runs without touching the phone, and it is what will actually be used while developing the Mac side.
- **Manual acceptance**: send myself a WhatsApp message, a banner appears on the Mac within a second. Clear it on the phone, the banner leaves Notification Center.

## Out of scope for v1

Deliberately cut, and each one should stay cut unless there is a concrete reason:

- Queueing for an offline Mac (violates principle 2, and the machinery to detect the Mac's return violates principle 1)
- Replying or acting on notifications from the Mac
- Mac → phone dismissal (dismissing on the Mac does not clear the phone)
- Multiple Macs
- Working off-LAN, over the internet, or via a relay
