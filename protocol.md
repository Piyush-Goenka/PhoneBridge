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
- 413 request body too large (cap 2 MiB).
- The phone treats any failure as drop-and-forget (best effort, no queue).
