# PhoneBridge wire protocol, v1

Source of truth for the Android to Mac contract. Both apps implement this file.

## Discovery

The Mac advertises Bonjour service type `_phonenotif._tcp.` (default port 52735,
but the advertised and QR port is authoritative). The phone resolves on demand,
caches host and port, and re-resolves once on connection failure.

## Security

- TLS 1.2+ with a self-signed certificate. The phone verifies nothing about the
  chain or hostname; it checks exactly one thing: SHA-256 of the leaf
  certificate DER equals the pinned fingerprint from the QR code.
- Mutual TLS: the phone holds an EC P-256 keypair in the Android Keystore and
  presents its self-signed certificate on every connection. After a phone has
  enrolled (see `/enroll`), the Mac runs **locked**: the TLS handshake requires
  exactly the enrolled certificate, so unknown peers never reach HTTP. The Mac
  runs **open** (no client cert required) only while no phone is enrolled or
  the pairing QR window is showing.
- Every request carries `Authorization: Bearer <token>`. Missing or wrong token
  gets `401 {"error":"unauthorized"}`.
- All endpoints accept only POST; other methods get
  `405 {"error":"method not allowed"}`.

## Validation

The Mac rejects (400) any request violating these bounds; the phone truncates
fields before sending so real notifications are trimmed, not dropped.

- `v` must be `1` on `/notify`, `/call`, and `/enroll` (`"bad version"`).
- `postedAt` (epoch milliseconds) must be at most 24 h in the past and 1 h in
  the future of the Mac's clock (`"stale timestamp"`).
- Field lengths: `key`/`pkg` ≤ 256, `appName` ≤ 128, `title` ≤ 512,
  `text` ≤ 4096, `caller` ≤ 256 characters (`"bad field"`).
- `iconHash` is `""` or exactly `sha256:` + 64 lowercase hex.
- `/icon` uploads must be ≤ 512 KiB, start with the PNG signature, and hash
  (SHA-256) to exactly `iconHash` (`"bad icon"` / `"hash mismatch"`).

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

### POST /call

```json
{"v":1,"key":"0|com.google.android.dialer|1|null|10","caller":"Palak","postedAt":1768500000000}
```

Response `200 {}`. Shows an actionable Incoming Call banner (Answer, Reject,
Silence) on the Mac.

An optional `"update":true` field marks a caller-name refresh for a call
already shown (the dialer first posts the carrier caller-ID name, then
re-posts once its contact lookup resolves). On an update the Mac rewrites the
existing banner and history entry in place: no new sound, no timer reset, no
new banner. An update whose banner is already gone only touches history.
Absent or false means a new call.

An optional `"state"` field reports that an already-shown call changed:

- `"active"` — the phone answered (because Answer was clicked on the Mac).
  The banner switches to its in-call form, offering only **End call**.
- `"silenced"` — the ringer was muted; the call is still ringing, so the
  banner stays and marks Silence as done.

The phone sends `state` only after the action actually succeeded, so the Mac
never claims something the phone did not do. `state` takes precedence over
`update`; an unknown value is treated as a plain new call.

### POST /call/wait

```json
{"key":"0|com.google.android.dialer|1|null|10"}
```

Held open by the Mac for up to 45 seconds, then
`200 {"action":"answer"|"reject"|"silence"|"end"|"none"}`. The action reflects the
button clicked on the Mac banner; `none` means timeout or banner dismissed.
Clients must use a read timeout of at least 50 seconds for this endpoint only.

A call can take more than one command (Silence then Answer, Answer then End
call), so the phone **re-issues `/call/wait` in a loop** for as long as the
call session lives, rather than waiting once. `none` is a poll timeout, not an
instruction: the phone simply waits again. The loop ends when the call ends,
or on `reject`/`end`, or when the request fails.

Because the phone re-polls, a click can land in the gap between two waits. The
Mac holds one such action per key and hands it to the next wait, so a button
press is never lost. Timeouts are never buffered this way, and `/dismiss`
clears any unclaimed action so a stale click cannot reach a later call.

A phone-side `/dismiss` for the same key fulfills any pending wait with `none`
and closes the banner. The phone sends it when the ring ends (dialer
notification removed) and when the call is answered *on the phone itself*, so
the Mac banner never outlives its usefulness. A call answered *from the Mac*
is the exception: it stays on screen, in its in-call form, until the call is
actually over.

### POST /enroll

```json
{"v":1,"cert":"<base64 DER of the phone's client certificate>"}
```

Registers the phone's mutual-TLS certificate. Accepted (`200 {}`) only while
the Mac is in open mode; in locked mode it returns `403 {"error":"locked"}`,
which an already-enrolled phone treats as success (reaching the endpoint at
all required its certificate). Invalid DER gets `400 {"error":"bad cert"}`.
The phone calls this once right after pairing and retries after any
successful send until it succeeds; a new enrollment replaces the previous
certificate (single-phone model).

## Errors

- 401 bad/missing token, 400 malformed JSON or failed validation (see
  Validation), 403 enroll while locked, 404 unknown path, 405 non-POST.
- 413 request body too large (cap 2 MiB).
- The phone treats any failure as drop-and-forget (best effort, no queue).
