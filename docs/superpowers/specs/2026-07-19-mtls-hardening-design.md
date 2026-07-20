# Mutual TLS hardening for the PhoneBridge server

Date: 2026-07-19
Status: Draft, pending review

## Problem

The Mac bridge server binds `0.0.0.0:52735`, so it is reachable on every
network the Mac joins (home LAN, office, public Wi-Fi, VPN). Today the phone
verifies the Mac cryptographically at the TLS handshake (pinned certificate
fingerprint), but the Mac verifies the phone only at the HTTP layer (Bearer
token). An unknown peer on the same network can therefore:

- complete a full TLS handshake with the server,
- feed arbitrary HTTP bytes into SwiftNIO's parser before being rejected
  with 401,
- fingerprint the service ("a PhoneBridge runs here") and hammer it.

No data is exposed and no endpoint works without the token, but the
unauthenticated attack surface (TLS + HTTP parsing) is larger than it needs
to be, and a leaked token alone is sufficient to fully impersonate the phone.

## Goal

Move phone authentication down into the TLS handshake (mutual TLS) so that
unknown peers are dropped before a single HTTP byte is parsed, and add cheap
exposure-minimizing hardening around it. After this change:

1. In steady state, a connection from anything other than the paired phone
   fails at the TLS handshake.
2. A leaked pairing token alone is no longer sufficient to reach any
   endpoint; the attacker would also need the phone's private key, which is
   hardware-backed and non-exportable.
3. Discovery (subnet sweep, cached IP, Bonjour) keeps working unchanged from
   the user's point of view.

## Current architecture (relevant parts)

- Mac server: SwiftNIO + NIOSSL. `BridgeServer.start` loads the server cert
  and key and builds one `NIOSSLContext` with
  `TLSConfiguration.makeServerConfiguration` (no client cert handling).
  All endpoints in `RequestHandler` check `Authorization: Bearer <token>`.
- Pairing: `Pairing.ensure` generates a self-signed server cert and a random
  token. The QR carries `{host, port, token, fp}` where `fp` is the SHA-256
  of the server cert DER.
- Android: `PairingStore` (SharedPreferences) holds token, fingerprint,
  host, port. `PinnedTls` builds a trust manager that accepts exactly the
  pinned fingerprint. `MacClient` (OkHttp) sends the Bearer token.
  `SweepProber` finds the Mac by completing a pinned TLS handshake against
  candidate IPs.
- Pairing window: `AppState.showQRWindow` shows the QR in an `NSWindow`;
  nothing today reacts to it opening or closing.

## Design

### 1. Phone client identity (Android)

At pairing time (right after a successful QR scan), the phone creates a
client identity if it does not already have one:

- Generate an EC P-256 keypair in the **Android Keystore**
  (`KeyPairGenerator` with provider `AndroidKeyStore`, purpose SIGN/VERIFY,
  alias `phonebridge-client`). The Keystore wraps the keypair in a
  self-signed X.509 certificate (subject `CN=PhoneBridge Phone`, long
  validity, these fields carry no trust meaning).
- The private key is hardware-backed and non-exportable. It cannot leave the
  device via backups, adb, or root. Only its certificate (public half) ever
  travels.
- A new `ClientIdentity` object in `net/` owns creation and lookup, and
  exposes an `X509ExtendedKeyManager` backed by the Keystore entry
  (`KeyManagerFactory("X509")` over the `AndroidKeyStore` keystore).

`PinnedTls.socketFactory` gains the key manager: `SSLContext.init(keyManagers,
trustManagers, null)`. Both `MacClient` and `SweepProber` build their socket
factories through the same path, so every TLS connection the phone makes
(requests and discovery probes) presents the client certificate.

### 2. Enrollment endpoint (Mac)

New endpoint `POST /enroll`, handled in `RequestHandler`:

- Auth: same Bearer token check as every other endpoint.
- Body: `{"v": 1, "cert": "<base64 DER>"}`.
- Gate: enrollment is accepted only when the server is in **open mode**
  (defined below). In locked mode it returns 403.
- Action: parse and validate the DER as X.509, write it to
  `Application Support/PhoneBridge/phone-cert.pem` (permissions 0600,
  replacing any previous one, single-phone model), then switch the server to
  locked mode.
- Response: `{}` with 200.
- Success is reported to the app layer through an `onEnrolled` callback on
  `RequestHandler`, so `AppState` can flip the server to locked mode and
  close the QR window.

Proof of possession of the private key is deliberately not required: the
endpoint is token-gated, and an attacker with the token could enroll a cert
they do hold the key for anyway, so a possession challenge adds complexity
without adding security.

### 3. Server modes (Mac)

`BridgeServer` gains two TLS configurations built from the same server
cert/key:

- **Open mode** (today's behavior): client certificates neither requested
  nor required. Active only when pairing is possible:
  - no `phone-cert.pem` exists yet (fresh install or after a pairing reset),
  - or the pairing QR window is currently open.
- **Locked mode** (steady state): `certificateVerification =
  .noHostnameVerification` with `trustRoots =
  .certificates([phoneCert])`. The handshake requires the peer to present
  exactly the enrolled certificate and prove possession of its key. Unknown
  peers never reach the HTTP pipeline.

Mode switching restarts the listener (`stop()` then `start(...)`) with the
other `NIOSSLContext`. The port is fixed, `SO_REUSEADDR` is already set, and
the existing EADDRINUSE retry loop in `start` absorbs the brief overlap.
In-flight phone connections are short-lived HTTP requests except
`/call/wait`; the phone already treats a dropped wait as retryable.

`AppState` drives the mode:

- On launch: locked if `phone-cert.pem` exists, otherwise open.
- `showQRWindow`: switch to open mode. Closing the QR window (observed via
  `NSWindow.willCloseNotification`) switches back to locked if a phone cert
  exists. Successful enrollment also closes the window and locks.

Implementation note to verify with a test: NIOSSL must reject handshakes
where the client presents no certificate at all in locked mode (OpenSSL's
`SSL_VERIFY_FAIL_IF_NO_PEER_CERT` semantics). If NIOSSL treats the cert as
optional, add a channel handler that queries the peer certificate after
handshake and closes the connection when absent.

### 4. Pairing and migration flows

Fresh pairing (new install on both sides):

1. Mac starts with no phone cert: open mode. User opens the QR window.
2. Phone scans QR, stores token/fingerprint/host/port (unchanged), creates
   its Keystore identity, calls `/enroll` over the pinned TLS + token
   channel.
3. Mac stores the cert, locks, closes the QR window. Every later connection
   is mutual TLS.

Migration (already-paired phone, both apps updated):

1. Updated Mac app finds no `phone-cert.pem`: stays in open mode, exactly
   today's security level, nothing breaks.
2. Updated phone app notices it has a pairing but no client identity:
   creates one and calls `/enroll` before its next send (open mode accepts
   it because no cert is enrolled yet).
3. Server locks. No user action, no re-pair needed.

Re-pair / new phone / reinstall:

1. User opens the QR window on the Mac: open mode (this is the physical
   consent step).
2. New phone scans and enrolls; its cert replaces the old one. The old
   phone's cert stops working at the next handshake.

Phone-side failure handling: if the phone holds a client identity but the
handshake fails in a way the pinned trust manager did not cause (server
rejected *our* cert, e.g. after a Mac-side reset), surface the existing
"re-pair needed" state in the app UI. Scanning the QR again re-enrolls.

### 5. Exposure minimization (defense in depth)

- **Private-source gate**: in the server channel initializer, before any TLS
  handler runs, read `channel.remoteAddress` and close the connection
  unless it is loopback, RFC 1918 (10/8, 172.16/12, 192.168/16), link-local
  169.254/16, or CGNAT 100.64/10 (VPNs like Tailscale hand out these).
  This never blocks a legitimate peer today (the phone reaches the Mac over
  LAN or VPN, both in-range) and guarantees nothing internet-routed can
  touch the TLS stack even if the port ever gets forwarded.
- **Quiet rejection**: rejected connections (bad source IP, failed
  handshake) are closed without any application-layer response, so a
  scanner learns only "TLS service, handshake refused", not what it is.
  The 401 JSON body remains only for token failures in open mode, where the
  phone's UX needs it.
- Rate limiting of handshake attempts is deliberately out: in locked mode a
  stranger costs one refused handshake, and NIOSSL does that work before any
  app code runs. Complexity is not justified.

### 6. What does not change

- QR payload format and size, `PairingStore` fields, discovery logic
  (sweep plan, host resolver, Bonjour), all existing endpoints and their
  payloads, the fixed port contract, and the phone-side server pinning.
- The server still binds `0.0.0.0`. That is now safe by construction:
  reachability no longer implies any unauthenticated surface beyond a
  refused handshake.

## Error handling

- `/enroll` with malformed base64 or DER: 400, nothing stored, mode
  unchanged.
- Cert file write failure: 500, mode unchanged; the phone retries on next
  send.
- Corrupt/unreadable `phone-cert.pem` at launch: treat as absent (open
  mode) and log; the phone re-enrolls automatically via the migration path.
- Listener restart failure when switching modes: keep the old listener
  running, surface the error in `statusLine`.
- Keystore unavailable on the phone (rare old devices): fall back to
  rejecting pairing with a clear error rather than silently downgrading.
- Version skew: an updated phone talking to an old Mac app gets 404 from
  `/enroll`. The phone treats 404 as "Mac not ready", keeps sending
  normally, and retries enrollment on a later connection.

## Testing

Mac (`PhoneBridgeCoreTests`, extend `ServerIntegrationTests` which already
spins up a real server):

- Locked mode rejects a handshake with no client cert.
- Locked mode rejects a handshake with a different (freshly generated)
  client cert.
- Locked mode accepts the enrolled cert and serves `/notify`.
- Open mode accepts `/enroll` with valid token, rejects without token,
  rejects in locked mode (403).
- Enrollment replaces the previous cert; old cert then fails.
- Private-source gate: unit-test the range predicate; integration-test that
  a loopback connection passes.
- Corrupt `phone-cert.pem` falls back to open mode.

Android: unit tests for `ClientIdentity` creation/reuse and for the
enrollment call path (against a local test server or with OkHttp
MockWebServer where TLS details allow). The pinned-trust behavior tests that
exist today must keep passing with the key manager added.

End-to-end (manual): fresh pair, migration from a token-only pairing,
re-pair with QR window, sweep discovery after an IP change, VPN path.

## Out of scope (tracked separately)

- Finding #2 remainder: `android:allowBackup="false"` and moving the token
  into EncryptedSharedPreferences. This design already removes most of the
  token's value, but the manifest/storage fix is a separate small change.
- Multi-phone support (the single `phone-cert.pem` model matches the
  single-token, single-`PairingStore` design).
- Rotating the server certificate or token.
